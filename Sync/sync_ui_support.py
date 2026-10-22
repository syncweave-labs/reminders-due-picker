"""U09 app-facing support for per-list policy editing and conflict review.

This module adds the read/preview/save surface the signed app needs to let the
owner edit per-list sync policy (U09-A) and review individual conflicts
(U09-B). It is deliberately thin: every semantic decision still belongs to
``icloud_reminders_google_sync`` (the engine). This file only:

* reshapes the engine's ``list_sync_policy`` output into
  effective/inherited/override triples for the UI,
* validates edits through the engine's existing ``normalize_list_policies``
  and per-key rules (no new enums, no arbitrary config keys),
* computes a config fingerprint so a save can refuse to clobber a config that
  changed on disk after it was read,
* derives opaque, account-bound conflict records with both revisions and the
  field differences the UI compares, and
* keeps only counts/categories in ``status.json``: never a title, note, date,
  or account value.

No function here mutates Apple Reminders or Google Tasks. Saving policy only
rewrites ``config.json``; the next sync plan picks the new policy up. Applying a
conflict choice is the engine's job and still runs through the existing
mutation planner and destructive-approval gates.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any, Callable

import icloud_reminders_google_sync as engine


# --- config fingerprint ------------------------------------------------------

#: Only the keys that change sync behaviour participate in the fingerprint, so
#: an unrelated status/runtime rewrite does not force the UI to re-read. The set
#: is intentionally derived from the engine's own policy vocabulary plus the
#: top-level defaults each per-list override can inherit from.
POLICY_FINGERPRINT_KEYS: tuple[str, ...] = (
    "list_policies",
    "include_lists",
    "bidirectional",
    "delete_stale",
    "tasks_sync_undated",
    "conflict_policy",
)


def config_fingerprint(config: dict[str, Any]) -> str:
    """Opaque hash of the policy-relevant subset of a config."""
    material = {key: config.get(key) for key in POLICY_FINGERPRINT_KEYS}
    return engine.sha256_text(engine.canonical_json(material))


# --- effective vs inherited vs override policy (U09-A) -----------------------

def _default_policy(config: dict[str, Any]) -> dict[str, Any]:
    """The policy a list with no override inherits from the top-level config."""
    return {
        "direction": "bidirectional" if config.get("bidirectional") else "apple_to_google",
        "delete_propagation": bool(config.get("delete_stale")),
        "sync_undated": bool(config.get("tasks_sync_undated")),
        "conflict_policy": str(config.get("conflict_policy") or "skip"),
    }


def effective_list_policies(
    config: dict[str, Any],
    list_titles: list[str],
) -> list[dict[str, Any]]:
    """Per-list effective policy with its inherited default and any override.

    ``list_titles`` is the set of Apple Reminders list titles the app observed
    (name-keyed, which is the engine's current identity). Lists that only exist
    as an override but are no longer present are still surfaced so a stale
    override is visible rather than silently applied to nothing.
    """
    policies = config.get("list_policies") or {}
    override_titles = list(policies) if isinstance(policies, dict) else []
    present = {str(title) for title in list_titles}
    ordered: list[str] = []
    seen: set[str] = set()
    for title in [*list_titles, *override_titles]:
        key = str(title)
        if key and key not in seen:
            seen.add(key)
            ordered.append(key)

    inherited = _default_policy(config)
    result: list[dict[str, Any]] = []
    for title in ordered:
        override = policies.get(title, {}) if isinstance(policies, dict) else {}
        override = override if isinstance(override, dict) else {}
        effective = engine.list_sync_policy(config, title)
        result.append(
            {
                "list_title": title,
                "present": title in present,
                "effective": effective,
                "inherited": inherited,
                "override": {key: override[key] for key in engine.LIST_POLICY_KEYS if key in override},
                "overridden_keys": sorted(
                    key for key in engine.LIST_POLICY_KEYS
                    if key in override and override[key] != inherited.get(key)
                ),
            }
        )
    return result


def policy_read(config: dict[str, Any], list_titles: list[str]) -> dict[str, Any]:
    """Read-only payload for the policy editor."""
    return {
        "ok": True,
        "fingerprint": config_fingerprint(config),
        "inherited": _default_policy(config),
        "directions": sorted(engine.LIST_POLICY_DIRECTIONS),
        "conflict_policies": sorted(engine.CONFLICT_POLICIES),
        "policy_keys": sorted(engine.LIST_POLICY_KEYS),
        "name_keyed": True,
        "lists": effective_list_policies(config, list_titles),
    }


def _validate_overrides(raw: Any) -> dict[str, dict[str, Any]]:
    """Reuse the engine's validator; never accept unknown keys or enums."""
    # normalize_list_policies raises SystemExit on any unsupported field or
    # value. Re-raise as ValueError so the bridge can answer with an error
    # payload instead of exiting the whole process.
    try:
        return engine.normalize_list_policies(raw)
    except SystemExit as exc:  # pragma: no cover - message passthrough
        raise ValueError(str(exc)) from exc


def preview_policy_save(
    config: dict[str, Any],
    overrides: Any,
) -> dict[str, Any]:
    """Validate an edit and show the effective policy it would produce.

    No file is written. The engine validator rejects unknown keys and any value
    outside the existing enums, so the preview cannot invent a new policy.
    """
    normalized = _validate_overrides(overrides)
    candidate = dict(config)
    candidate["list_policies"] = normalized
    titles = sorted({*(config.get("list_policies") or {}), *normalized})
    return {
        "ok": True,
        "fingerprint": config_fingerprint(config),
        "lists": effective_list_policies(candidate, titles),
    }


def apply_policy_save(
    config_path: Path,
    overrides: Any,
    expected_fingerprint: str,
    *,
    reader: Callable[[Path], dict[str, Any]] = engine.read_json,
    writer: Callable[[Path, dict[str, Any]], None] = engine.write_json_atomic,
) -> dict[str, Any]:
    """Atomically rewrite only ``list_policies`` if the config is unchanged.

    The caller is responsible for holding the worker-stop/lock contract before
    calling this. Here we re-read the config, compare its fingerprint with the
    one the editor read, and refuse with ``policy_stale`` if anything relevant
    changed under the editor. The write is private and atomic (the engine's
    ``write_json_atomic`` writes mode 0600 and replaces in place), and only the
    ``list_policies`` key is touched so concurrent unrelated fields are kept.
    """
    normalized = _validate_overrides(overrides)
    config_path = Path(config_path)
    current = reader(config_path) if config_path.exists() else {}
    if not isinstance(current, dict):
        raise ValueError("Config file is not a JSON object")
    if config_fingerprint(current) != expected_fingerprint:
        return {
            "ok": False,
            "state": "policy_stale",
            "fingerprint": config_fingerprint(current),
            "message": "설정이 편집 중에 바뀌었습니다. 최신 정책을 다시 불러온 뒤 저장하세요.",
        }
    updated = dict(current)
    updated["list_policies"] = normalized
    writer(config_path, updated)
    saved = reader(config_path)
    titles = sorted({*(current.get("list_policies") or {}), *normalized})
    return {
        "ok": True,
        "state": "saved",
        "fingerprint": config_fingerprint(saved),
        "lists": effective_list_policies(saved, titles),
    }


# --- conflict review (U09-B) -------------------------------------------------
#
# The engine already detects a two-sided change and, for the "skip" policy,
# refuses to overwrite either side. Historically it only printed the title and
# counted it. U09-B turns that into a reviewable record: an opaque, account-
# bound id, both revisions, the observation time, and the field differences the
# UI shows. Records live in a private, 0600 journal next to the other runtime
# state. status.json never receives any of these values -- only counts and
# categories (see ``conflict_status_summary``).

import json
import os
import datetime as _dt

#: Fields the UI compares between Apple Reminders and Google Tasks. Completion
#: and date are first-class because a forbidden-direction write of either is an
#: acceptance failure, so the UI must surface them explicitly.
CONFLICT_FIELDS: tuple[str, ...] = ("title", "notes", "due_date", "completed")


def _apple_side(reminder: dict[str, Any]) -> dict[str, Any]:
    return {
        "title": str(reminder.get("title") or ""),
        "notes": str(reminder.get("notes") or ""),
        "due_date": reminder.get("due_date") or (str(reminder.get("due_at") or "")[:10] or None),
        "completed": bool(reminder.get("is_completed")),
        "revision": str(reminder.get("modified_at") or ""),
    }


def _google_side(task: dict[str, Any]) -> dict[str, Any]:
    due = str(task.get("due") or "")
    return {
        "title": str(task.get("title") or ""),
        "notes": engine.strip_tasks_sync_metadata(str(task.get("notes") or "")),
        "due_date": due[:10] if len(due) >= 10 else None,
        "completed": str(task.get("status") or "needsAction") == "completed",
        "revision": str(task.get("etag") or task.get("updated") or ""),
    }


def _side_fingerprint(side: dict[str, Any]) -> str:
    material = {field: side.get(field) for field in CONFLICT_FIELDS}
    return engine.sha256_text(engine.canonical_json(material))


def conflict_identity(
    account_binding: dict[str, Any],
    list_title: str,
    uid: str,
) -> str:
    """Opaque, account-bound id. Stable across observations of the same item.

    It binds the Apple+Google account fingerprints so a conflict id from one
    account can never be applied against another; the engine still re-validates
    the account binding before writing.
    """
    material = {
        "apple": str((account_binding or {}).get("apple") or ""),
        "google": str((account_binding or {}).get("google") or ""),
        "list": str(list_title or ""),
        "uid": str(uid or ""),
    }
    return engine.sha256_text(engine.canonical_json(material), 24)


def build_conflict_record(
    account_binding: dict[str, Any],
    list_title: str,
    uid: str,
    reminder: dict[str, Any],
    task: dict[str, Any],
    *,
    observed_at: str | None = None,
) -> dict[str, Any]:
    """A reviewable conflict: opaque id, binding, both revisions, field diffs."""
    apple = _apple_side(reminder)
    google = _google_side(task)
    diffs = [
        {"field": field, "apple": apple.get(field), "google": google.get(field)}
        for field in CONFLICT_FIELDS
        if apple.get(field) != google.get(field)
    ]
    return {
        "conflict_id": conflict_identity(account_binding, list_title, uid),
        "account_binding": {
            "apple": str((account_binding or {}).get("apple") or ""),
            "google": str((account_binding or {}).get("google") or ""),
        },
        "list_title": list_title,
        "uid": uid,
        "observed_at": observed_at or _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "apple": apple,
        "google": google,
        # Raw sides kept in the private local journal so an offline re-read can
        # reconstruct the exact revision the record was built from. These never
        # reach status.json (only conflict_status_summary is written there).
        "apple_raw": reminder,
        "google_raw": task,
        "apple_fingerprint": _side_fingerprint(apple),
        "google_fingerprint": _side_fingerprint(google),
        "fields": diffs,
    }


def conflict_status_summary(records: list[dict[str, Any]]) -> dict[str, Any]:
    """Counts and categories only -- safe for status.json.

    Never includes a title, note, date value, or account fingerprint; only the
    number of conflicts and which fields differ, by count.
    """
    by_field: dict[str, int] = {}
    held = 0
    for record in records:
        if record.get("choice") == "hold":
            held += 1
        for diff in record.get("fields") or []:
            field = str(diff.get("field") or "")
            if field:
                by_field[field] = by_field.get(field, 0) + 1
    return {
        "open": sum(1 for r in records if r.get("choice") not in ("hold",)),
        "held": held,
        "total": len(records),
        "by_field": dict(sorted(by_field.items())),
    }


class ConflictJournal:
    """Private, 0600 journal of open conflicts and their chosen resolutions.

    Keyed by opaque conflict id. A record is replaced in place when the same
    conflict is observed again (revisions refreshed); a resolved record keeps
    its choice until the engine confirms the write, so a lost response does not
    drop the decision. Every write is atomic via the engine's writer.
    """

    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.directory, 0o700)
        self.path = self.directory / "conflicts.json"

    def _load(self) -> dict[str, dict[str, Any]]:
        if not self.path.exists():
            return {}
        try:
            data = engine.read_json(self.path)
        except (OSError, json.JSONDecodeError):
            return {}
        return data if isinstance(data, dict) else {}

    def _store(self, records: dict[str, dict[str, Any]]) -> None:
        engine.write_json_atomic(self.path, records)

    def records(self) -> list[dict[str, Any]]:
        return list(self._load().values())

    def observe(self, record: dict[str, Any]) -> None:
        """Record or refresh one conflict, preserving a pending choice."""
        records = self._load()
        existing = records.get(record["conflict_id"])
        if existing and existing.get("choice"):
            # A fresh observation of a still-open conflict means the revisions
            # changed; drop a stale choice so the user re-decides against the
            # new revisions rather than applying to data they did not see.
            same = (
                existing.get("apple_fingerprint") == record["apple_fingerprint"]
                and existing.get("google_fingerprint") == record["google_fingerprint"]
            )
            if same:
                record["choice"] = existing["choice"]
        records[record["conflict_id"]] = record
        self._store(records)

    def reconcile(self, observed_ids: set[str]) -> None:
        """Drop conflicts no longer observed (resolved on one side already)."""
        records = self._load()
        remaining = {cid: rec for cid, rec in records.items() if cid in observed_ids}
        if remaining != records:
            self._store(remaining)

    def set_choice(self, conflict_id: str, choice: str) -> None:
        records = self._load()
        if conflict_id in records:
            records[conflict_id]["choice"] = choice
            self._store(records)

    def remove(self, conflict_id: str) -> None:
        records = self._load()
        if conflict_id in records:
            records.pop(conflict_id, None)
            self._store(records)


# --- conflict resolution (U09-B apply) ---------------------------------------
#
# ``resolve_conflict`` takes only a conflict id, a choice and the revision the
# user saw. It re-reads both sides, refuses with ``conflict_stale`` if either
# moved, routes the single chosen write through the existing mutation planner
# and destructive-approval gate, and records the operation so a lost response
# or a crash after a one-sided success recovers by read-back rather than
# blindly re-writing.

class ConflictResolutionJournal:
    """Per-operation journal: operation id -> {choice, fingerprints, result}.

    The entry is persisted BEFORE the write, so a crash in the middle is
    recoverable: on retry we read the recorded target back and reconcile
    instead of applying a second time. A terminal result is kept so a duplicate
    click returns the same outcome.
    """

    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.directory, 0o700)
        self.path = self.directory / "resolutions.json"

    def _load(self) -> dict[str, dict[str, Any]]:
        if not self.path.exists():
            return {}
        try:
            data = engine.read_json(self.path)
        except (OSError, json.JSONDecodeError):
            return {}
        return data if isinstance(data, dict) else {}

    def _store(self, entries: dict[str, dict[str, Any]]) -> None:
        engine.write_json_atomic(self.path, entries)

    def lookup(self, operation_id: str) -> dict[str, Any] | None:
        return self._load().get(operation_id)

    def begin(self, operation_id: str, entry: dict[str, Any]) -> None:
        entries = self._load()
        entries[operation_id] = {**entry, "result": None}
        self._store(entries)

    def finish(self, operation_id: str, result: dict[str, Any]) -> None:
        entries = self._load()
        if operation_id in entries:
            entries[operation_id]["result"] = result
            self._store(entries)


CONFLICT_CHOICES: tuple[str, ...] = ("apple", "google", "hold")


def resolve_conflict(
    config: dict[str, Any],
    journal: ConflictJournal,
    resolutions: ConflictResolutionJournal,
    conflict_id: str,
    choice: str,
    expected_revision: dict[str, str],
    *,
    operation_id: str,
    read_apple: Callable[[str, str], dict[str, Any] | None],
    read_google: Callable[[str, str], dict[str, Any] | None],
    apply_change: Callable[[dict[str, Any]], dict[str, Any]],
    account_binding: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Apply one conflict choice through the mutation planner and gate.

    * ``choice`` is one of apple|google|hold. "hold" keeps the conflict and
      touches no remote data.
    * ``expected_revision`` is ``{"apple": ..., "google": ...}`` the UI saw.
    * ``read_apple``/``read_google`` re-read the single item under the caller's
      lock; the bridge passes engine-backed readers, tests pass fakes.
    * ``apply_change`` runs the single planned write; it must itself go through
      ``enforce_mutation_plan`` (the bridge wires the real one; tests assert the
      gate is consulted).

    Returns a dict with ``state`` in {resolved, held, conflict_stale,
    conflict_gone, invalid_choice}.
    """
    if choice not in CONFLICT_CHOICES:
        return {"ok": False, "state": "invalid_choice", "conflict_id": conflict_id}

    # Idempotent replay: a terminal result for this operation id is returned
    # as-is; an unfinished entry is reconciled by read-back below.
    prior = resolutions.lookup(operation_id)
    if prior and prior.get("result") is not None:
        return prior["result"]

    record = next((r for r in journal.records() if r.get("conflict_id") == conflict_id), None)
    if record is None:
        return {"ok": False, "state": "conflict_gone", "conflict_id": conflict_id}

    if choice == "hold":
        journal.set_choice(conflict_id, "hold")
        result = {"ok": True, "state": "held", "conflict_id": conflict_id}
        return result

    list_title = str(record.get("list_title") or "")
    uid = str(record.get("uid") or "")

    # Account binding must match the record's binding so a conflict id minted
    # for one account can never be applied against another.
    binding = account_binding or {}
    record_binding = record.get("account_binding") or {}
    if binding and (
        str(binding.get("apple") or "") != str(record_binding.get("apple") or "")
        or str(binding.get("google") or "") != str(record_binding.get("google") or "")
    ):
        return {"ok": False, "state": "account_changed", "conflict_id": conflict_id}

    apple_now = read_apple(list_title, uid)
    google_now = read_google(list_title, uid)
    if apple_now is None or google_now is None:
        # One side vanished after selection -> reject rather than guess.
        journal.remove(conflict_id)
        return {"ok": False, "state": "conflict_gone", "conflict_id": conflict_id}

    apple_side = _apple_side(apple_now)
    google_side = _google_side(google_now)
    current = {"apple": apple_side["revision"], "google": google_side["revision"]}
    if (
        str(expected_revision.get("apple") or "") != current["apple"]
        or str(expected_revision.get("google") or "") != current["google"]
    ):
        # Refresh the record against what we just read, then reject.
        refreshed = build_conflict_record(record_binding, list_title, uid, apple_now, google_now)
        journal.observe(refreshed)
        return {
            "ok": False,
            "state": "conflict_stale",
            "conflict_id": conflict_id,
            "current_revision": current,
            "expected_revision": {
                "apple": str(expected_revision.get("apple") or ""),
                "google": str(expected_revision.get("google") or ""),
            },
        }

    # Persist the intent before the write; recovery reads the target back.
    resolutions.begin(
        operation_id,
        {
            "conflict_id": conflict_id,
            "choice": choice,
            "expected_revision": current,
            "list_title": list_title,
            "uid": uid,
        },
    )

    try:
        applied = apply_change(
            {
                "choice": choice,
                "list_title": list_title,
                "uid": uid,
                "apple": apple_now,
                "google": google_now,
            }
        )
    except engine.MutationPlanApprovalRequired as exc:
        # The destructive gate blocked this exactly as it would in bulk sync.
        result = {
            "ok": False,
            "state": "blocked_mutation_plan",
            "conflict_id": conflict_id,
            "message": str(exc),
        }
        resolutions.finish(operation_id, result)
        return result

    result = {
        "ok": True,
        "state": "resolved",
        "conflict_id": conflict_id,
        "choice": choice,
        "applied": applied,
    }
    resolutions.finish(operation_id, result)
    journal.remove(conflict_id)
    return result
