"""U09 regression tests: per-list policy editing and individual conflict review.

Every test uses temp dirs, fake Apple/Google data and the engine's real policy
and mutation-gate functions. Nothing here touches real Reminders or Google
Tasks, matches the service AGENTS boundary (the engine uses fakes; EventKit is
never invoked).
"""
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

import icloud_reminders_google_sync as engine
import sync_ui_support as ui


def base_config(tmp: Path) -> dict:
    config = engine.default_config()
    config.update(
        state_path=str(tmp / "state.json"),
        status_path=str(tmp / "status.json"),
        bidirectional=True,
        delete_stale=False,
        conflict_policy="skip",
        tasks_sync_undated=False,
        list_policies={},
        include_lists=[],
        # Keep the destructive gate tight so a single completion trips it.
        max_destructive_changes=0,
        max_destructive_ratio=0.0,
    )
    return config


def write_config(tmp: Path, config: dict) -> Path:
    path = tmp / "config.json"
    engine.write_json_atomic(path, config)
    return path


# --- U09-A policy UI ---------------------------------------------------------

class PolicyReadTests(unittest.TestCase):
    def test_effective_inherited_and_override_are_distinguished(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            config["list_policies"] = {"Work": {"direction": "apple_to_google"}}
            payload = ui.policy_read(config, ["Work", "Home"])
            by_title = {row["list_title"]: row for row in payload["lists"]}
            # Inherited default comes from bidirectional=True.
            self.assertEqual(payload["inherited"]["direction"], "bidirectional")
            self.assertEqual(by_title["Work"]["effective"]["direction"], "apple_to_google")
            self.assertIn("direction", by_title["Work"]["overridden_keys"])
            self.assertEqual(by_title["Home"]["effective"]["direction"], "bidirectional")
            self.assertEqual(by_title["Home"]["overridden_keys"], [])
            # Only the existing enums are ever offered.
            self.assertEqual(set(payload["directions"]), engine.LIST_POLICY_DIRECTIONS)
            self.assertEqual(set(payload["conflict_policies"]), engine.CONFLICT_POLICIES)

    def test_name_keyed_limitation_is_shown_honestly(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            # An override for a list title that is no longer present.
            config["list_policies"] = {"Archived": {"direction": "google_to_apple"}}
            payload = ui.policy_read(config, ["Home"])
            self.assertTrue(payload["name_keyed"])
            by_title = {row["list_title"]: row for row in payload["lists"]}
            self.assertFalse(by_title["Archived"]["present"])
            self.assertTrue(by_title["Home"]["present"])


class PolicySaveTests(unittest.TestCase):
    def test_preview_and_save_reject_unknown_keys_and_enums(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            with self.assertRaises(ValueError):
                ui.preview_policy_save(config, {"Work": {"direction": "sideways"}})
            with self.assertRaises(ValueError):
                ui.preview_policy_save(config, {"Work": {"unknown_key": True}})

    def test_save_never_mutates_reminders_or_tasks_only_config(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            path = write_config(tmp, config)
            fp = ui.config_fingerprint(config)
            result = ui.apply_policy_save(path, {"Work": {"direction": "apple_to_google"}}, fp)
            self.assertTrue(result["ok"])
            saved = json.loads(path.read_text())
            # Only list_policies changed; every other key is byte-identical.
            before = dict(config)
            after = dict(saved)
            self.assertEqual(after["list_policies"], {"Work": {"direction": "apple_to_google"}})
            before.pop("list_policies"); after.pop("list_policies")
            self.assertEqual(before, after)
            # No state/status file was created by a save.
            self.assertFalse((tmp / "state.json").exists())

    def test_cancel_leaves_config_bytes_unchanged(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            path = write_config(tmp, config)
            before = path.read_bytes()
            # A preview is the "cancel" path: validate, show, write nothing.
            ui.preview_policy_save(config, {"Work": {"direction": "apple_to_google"}})
            self.assertEqual(path.read_bytes(), before)

    def test_stale_fingerprint_refuses_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            path = write_config(tmp, config)
            stale_fp = ui.config_fingerprint(config)
            # Something else changed the config after the editor read it.
            changed = dict(config)
            changed["list_policies"] = {"Other": {"sync_undated": True}}
            engine.write_json_atomic(path, changed)
            before = path.read_bytes()
            result = ui.apply_policy_save(path, {"Work": {"direction": "apple_to_google"}}, stale_fp)
            self.assertFalse(result["ok"])
            self.assertEqual(result["state"], "policy_stale")
            self.assertEqual(path.read_bytes(), before)

    def test_save_is_atomic_no_half_written_config(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            path = write_config(tmp, config)
            fp = ui.config_fingerprint(config)

            calls = {"n": 0}
            real_writer = engine.write_json_atomic

            def exploding_writer(p, payload):
                calls["n"] += 1
                raise OSError("disk full mid-write")

            with self.assertRaises(OSError):
                ui.apply_policy_save(path, {"Work": {"direction": "apple_to_google"}}, fp, writer=exploding_writer)
            # The original config is intact and still valid JSON.
            loaded = json.loads(path.read_text())
            self.assertEqual(loaded["list_policies"], {})
            self.assertEqual(calls["n"], 1)
            # And the real atomic writer leaves no stray temp file behind.
            real_writer(path, config)
            self.assertEqual(sorted(p.name for p in tmp.iterdir() if p.name.startswith("config")), ["config.json"])

    def test_delete_propagation_toggle_is_not_a_destructive_approval(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            path = write_config(tmp, config)
            fp = ui.config_fingerprint(config)
            result = ui.apply_policy_save(path, {"Work": {"delete_propagation": True}}, fp)
            self.assertTrue(result["ok"])
            saved = json.loads(path.read_text())
            # The toggle only changes config; no mutation plan or approval token
            # is produced, and no reminder/task write happens.
            self.assertEqual(saved["list_policies"], {"Work": {"delete_propagation": True}})
            self.assertNotIn("_mutation_plan_approval", saved)


# --- U09-B conflict review ---------------------------------------------------

def apple_item(uid="u1", title="Report", notes="", due="2026-10-20", completed=False, modified="2026-10-20T09:00:00Z", list_title="Work"):
    return {
        "id": uid, "stable_id": uid, "external_id": uid, "list_title": list_title,
        "title": title, "notes": notes, "due_date": due, "is_completed": completed,
        "modified_at": modified,
    }


def google_task(title="Report v2", notes="", due="2026-10-22T00:00:00.000Z", status="needsAction", etag="etag-1"):
    return {"id": "g1", "title": title, "notes": notes, "due": due, "status": status, "etag": etag}


def binding():
    return {"version": 1, "apple": "apple-fp", "google": "google-fp"}


class ConflictRecordTests(unittest.TestCase):
    def test_record_has_opaque_id_binding_revisions_and_field_diffs(self):
        rec = ui.build_conflict_record(binding(), "Work", "u1", apple_item(), google_task())
        self.assertEqual(len(rec["conflict_id"]), 24)
        self.assertEqual(rec["account_binding"], {"apple": "apple-fp", "google": "google-fp"})
        self.assertTrue(rec["apple_fingerprint"])
        self.assertTrue(rec["google_fingerprint"])
        fields = {d["field"] for d in rec["fields"]}
        # title and due_date differ; notes and completed do not.
        self.assertIn("title", fields)
        self.assertIn("due_date", fields)
        self.assertNotIn("completed", fields)
        self.assertIn("observed_at", rec)

    def test_id_is_stable_across_observations_and_binds_account(self):
        a = ui.conflict_identity(binding(), "Work", "u1")
        b = ui.conflict_identity(binding(), "Work", "u1")
        other = ui.conflict_identity({"apple": "x", "google": "y"}, "Work", "u1")
        self.assertEqual(a, b)
        self.assertNotEqual(a, other)

    def test_status_summary_has_counts_only_never_private_values(self):
        records = [
            ui.build_conflict_record(binding(), "Work", "u1", apple_item(title="Secret Title"), google_task()),
            {**ui.build_conflict_record(binding(), "Work", "u2", apple_item(uid="u2"), google_task()), "choice": "hold"},
        ]
        summary = ui.conflict_status_summary(records)
        blob = json.dumps(summary, ensure_ascii=False)
        self.assertNotIn("Secret Title", blob)
        self.assertNotIn("apple-fp", blob)
        self.assertNotIn("Report", blob)
        self.assertEqual(summary["held"], 1)
        self.assertEqual(summary["total"], 2)
        self.assertIn("title", summary["by_field"])


class ConflictJournalTests(unittest.TestCase):
    def test_observe_refresh_preserves_choice_only_when_revisions_match(self):
        with tempfile.TemporaryDirectory() as t:
            j = ui.ConflictJournal(Path(t) / "Conflicts")
            rec = ui.build_conflict_record(binding(), "Work", "u1", apple_item(), google_task())
            j.observe(rec)
            j.set_choice(rec["conflict_id"], "apple")
            # Same content fingerprint -> choice survives even if the revision
            # timestamp moved (content is what the user decided on).
            j.observe(ui.build_conflict_record(binding(), "Work", "u1", apple_item(modified="2026-10-21T09:00:00Z"), google_task()))
            kept = next(r for r in j.records() if r["conflict_id"] == rec["conflict_id"])
            self.assertEqual(kept.get("choice"), "apple")
            # Changed content (a new title) -> choice dropped so the user re-decides.
            moved = ui.build_conflict_record(binding(), "Work", "u1", apple_item(title="Report EDITED"), google_task())
            j.observe(moved)
            after = next(r for r in j.records() if r["conflict_id"] == rec["conflict_id"])
            self.assertIsNone(after.get("choice"))

    def test_reconcile_drops_conflicts_no_longer_observed(self):
        with tempfile.TemporaryDirectory() as t:
            j = ui.ConflictJournal(Path(t) / "Conflicts")
            a = ui.build_conflict_record(binding(), "Work", "u1", apple_item(), google_task())
            b = ui.build_conflict_record(binding(), "Work", "u2", apple_item(uid="u2"), google_task())
            j.observe(a); j.observe(b)
            j.reconcile({a["conflict_id"]})
            ids = {r["conflict_id"] for r in j.records()}
            self.assertEqual(ids, {a["conflict_id"]})


class ConflictResolveTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        tmp = Path(self.tmpdir.name)
        self.config = base_config(tmp)
        self.journal = ui.ConflictJournal(tmp / "Conflicts")
        self.resolutions = ui.ConflictResolutionJournal(tmp / "Conflicts" / "Resolutions")
        self.reminder = apple_item()
        self.task = google_task()
        self.record = ui.build_conflict_record(binding(), "Work", "u1", self.reminder, self.task)
        self.journal.observe(self.record)
        self.apply_calls = []

    def tearDown(self):
        self.tmpdir.cleanup()

    _MISSING = object()

    def _readers(self, apple=_MISSING, google=_MISSING):
        apple = self.reminder if apple is self._MISSING else apple
        google = self.task if google is self._MISSING else google
        return (lambda lt, uid: apple), (lambda lt, uid: google)

    def _applier(self, raises=None):
        def apply_change(context):
            self.apply_calls.append(context)
            if raises:
                raise raises
            return {"side": context["choice"], "ok": True}
        return apply_change

    def test_hold_keeps_conflict_and_touches_no_remote_data(self):
        ra, rg = self._readers()
        result = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "hold",
            {"apple": self.record["apple"]["revision"], "google": self.record["google"]["revision"]},
            operation_id="op-hold", read_apple=ra, read_google=rg, apply_change=self._applier(),
            account_binding=binding(),
        )
        self.assertEqual(result["state"], "held")
        self.assertEqual(self.apply_calls, [])
        held = next(r for r in self.journal.records() if r["conflict_id"] == self.record["conflict_id"])
        self.assertEqual(held["choice"], "hold")

    def test_per_item_resolution_applies_one_chosen_write(self):
        ra, rg = self._readers()
        result = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "google",
            {"apple": self.reminder["modified_at"], "google": self.task["etag"]},
            operation_id="op-1", read_apple=ra, read_google=rg, apply_change=self._applier(),
            account_binding=binding(),
        )
        self.assertEqual(result["state"], "resolved")
        self.assertEqual(len(self.apply_calls), 1)
        # The resolved conflict is removed from the open set.
        self.assertEqual(self.journal.records(), [])

    def test_third_party_edit_after_selection_is_rejected_as_stale(self):
        moved = apple_item(modified="2026-10-21T10:00:00Z")
        ra, rg = self._readers(apple=moved)
        result = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "google",
            {"apple": self.reminder["modified_at"], "google": self.task["etag"]},
            operation_id="op-stale", read_apple=ra, read_google=rg, apply_change=self._applier(),
            account_binding=binding(),
        )
        self.assertEqual(result["state"], "conflict_stale")
        self.assertEqual(self.apply_calls, [])

    def test_item_deletion_after_selection_is_rejected(self):
        ra, rg = self._readers(apple=None)
        result = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "google",
            {"apple": self.reminder["modified_at"], "google": self.task["etag"]},
            operation_id="op-gone", read_apple=ra, read_google=rg, apply_change=self._applier(),
            account_binding=binding(),
        )
        self.assertEqual(result["state"], "conflict_gone")
        self.assertEqual(self.apply_calls, [])

    def test_account_change_after_selection_is_rejected(self):
        ra, rg = self._readers()
        result = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "google",
            {"apple": self.reminder["modified_at"], "google": self.task["etag"]},
            operation_id="op-acct", read_apple=ra, read_google=rg, apply_change=self._applier(),
            account_binding={"apple": "different", "google": "different"},
        )
        self.assertEqual(result["state"], "account_changed")
        self.assertEqual(self.apply_calls, [])

    def test_double_click_is_idempotent_and_applies_once(self):
        ra, rg = self._readers()
        rev = {"apple": self.reminder["modified_at"], "google": self.task["etag"]}
        first = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "google", rev,
            operation_id="op-dup", read_apple=ra, read_google=rg, apply_change=self._applier(), account_binding=binding(),
        )
        # Re-observe so the conflict exists again (as if a later sync re-saw it)
        self.journal.observe(self.record)
        second = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "google", rev,
            operation_id="op-dup", read_apple=ra, read_google=rg, apply_change=self._applier(), account_binding=binding(),
        )
        self.assertEqual(first["state"], "resolved")
        self.assertEqual(second, first)  # same terminal result returned
        self.assertEqual(len(self.apply_calls), 1)  # applied only once

    def test_one_side_success_then_lost_response_recovers_without_reapplying(self):
        ra, rg = self._readers()
        rev = {"apple": self.reminder["modified_at"], "google": self.task["etag"]}
        # First call: the apply succeeds but the "response is lost" -> simulate
        # by having the journal already hold a terminal result for this op id.
        ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "google", rev,
            operation_id="op-recover", read_apple=ra, read_google=rg, apply_change=self._applier(), account_binding=binding(),
        )
        self.assertEqual(len(self.apply_calls), 1)
        # Retry with the same operation id returns the stored result, no re-apply.
        self.journal.observe(self.record)
        again = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "google", rev,
            operation_id="op-recover", read_apple=ra, read_google=rg, apply_change=self._applier(), account_binding=binding(),
        )
        self.assertEqual(again["state"], "resolved")
        self.assertEqual(len(self.apply_calls), 1)

    def test_held_item_stays_held_while_unrelated_conflict_can_resolve(self):
        other_reminder = apple_item(uid="u2", title="Other")
        other_task = google_task(title="Other v2", etag="etag-2")
        other = ui.build_conflict_record(binding(), "Work", "u2", other_reminder, other_task)
        self.journal.observe(other)
        # Hold the first.
        ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "hold",
            {"apple": self.reminder["modified_at"], "google": self.task["etag"]},
            operation_id="op-hold2", read_apple=self._readers()[0], read_google=self._readers()[1],
            apply_change=self._applier(), account_binding=binding(),
        )
        # Resolve the unrelated one.
        ra = lambda lt, uid: other_reminder
        rg = lambda lt, uid: other_task
        ui.resolve_conflict(
            self.config, self.journal, self.resolutions, other["conflict_id"], "google",
            {"apple": other_reminder["modified_at"], "google": other_task["etag"]},
            operation_id="op-other", read_apple=ra, read_google=rg, apply_change=self._applier(), account_binding=binding(),
        )
        ids = {r["conflict_id"]: r for r in self.journal.records()}
        self.assertIn(self.record["conflict_id"], ids)  # held item still present
        self.assertEqual(ids[self.record["conflict_id"]]["choice"], "hold")
        self.assertNotIn(other["conflict_id"], ids)  # unrelated one resolved away

    def test_invalid_choice_is_rejected(self):
        ra, rg = self._readers()
        result = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "merge",
            {"apple": self.reminder["modified_at"], "google": self.task["etag"]},
            operation_id="op-bad", read_apple=ra, read_google=rg, apply_change=self._applier(), account_binding=binding(),
        )
        self.assertEqual(result["state"], "invalid_choice")
        self.assertEqual(self.apply_calls, [])

    def test_destructive_gate_block_is_surfaced_not_bypassed(self):
        ra, rg = self._readers()
        blocked = engine.MutationPlanApprovalRequired("blocked", {}, {})
        result = ui.resolve_conflict(
            self.config, self.journal, self.resolutions, self.record["conflict_id"], "google",
            {"apple": self.reminder["modified_at"], "google": self.task["etag"]},
            operation_id="op-block", read_apple=ra, read_google=rg,
            apply_change=self._applier(raises=blocked), account_binding=binding(),
        )
        self.assertEqual(result["state"], "blocked_mutation_plan")
        # The conflict remains open (not removed) because nothing was applied.
        self.assertIn(self.record["conflict_id"], {r["conflict_id"] for r in self.journal.records()})


class RecordConflictsForReviewTests(unittest.TestCase):
    def test_sync_records_conflicts_and_writes_only_counts_to_status(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            raw = [
                {"list_title": "Work", "uid": "u1", "reminder": apple_item(title="Private Apple Title"),
                 "task": google_task(title="Private Google Title")},
            ]
            engine.record_conflicts_for_review(config, binding(), raw)
            # Journal holds the full record (private local file).
            journal = ui.ConflictJournal(tmp / "Conflicts")
            records = journal.records()
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["list_title"], "Work")
            # status.json holds only the counts/categories summary.
            status = json.loads((tmp / "status.json").read_text())
            blob = json.dumps(status, ensure_ascii=False)
            self.assertIn("conflict_summary", status)
            self.assertNotIn("Private Apple Title", blob)
            self.assertNotIn("Private Google Title", blob)
            self.assertNotIn("apple-fp", blob)
            self.assertEqual(status["conflict_summary"]["total"], 1)

    def test_resolved_conflict_is_reconciled_out_on_next_sync(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = base_config(tmp)
            first = [{"list_title": "Work", "uid": "u1", "reminder": apple_item(), "task": google_task()}]
            engine.record_conflicts_for_review(config, binding(), first)
            # Next sync observes no conflicts -> journal reconciled to empty.
            engine.record_conflicts_for_review(config, binding(), [])
            journal = ui.ConflictJournal(tmp / "Conflicts")
            self.assertEqual(journal.records(), [])
            status = json.loads((tmp / "status.json").read_text())
            self.assertEqual(status["conflict_summary"]["total"], 0)


class InitialLinkMetadataExceptionTests(unittest.TestCase):
    """The documented exception: attaching sync metadata on first link is NOT a
    forbidden content write. The conflict diff and status summary ignore the
    engine's own sync-metadata block, so a metadata-only note never reads as a
    user-content conflict."""

    def test_sync_metadata_in_google_notes_is_not_a_content_conflict(self):
        reminder = apple_item(notes="my private note")
        # The Google task note carries only the engine's sync metadata, which
        # strip_tasks_sync_metadata removes before comparison.
        marked = engine.reminder_tasks_notes(reminder, "u1", "digest123")
        task = google_task(notes=marked)
        rec = ui.build_conflict_record(binding(), "Work", "u1", reminder, task)
        fields = {d["field"] for d in rec["fields"]}
        # The google side's visible notes are empty after stripping metadata, so
        # notes differs because the apple side has a real note -- but the
        # metadata itself never appears as google content.
        google_notes = next((d["google"] for d in rec["fields"] if d["field"] == "notes"), "")
        self.assertNotIn("Source Digest", str(google_notes or ""))
        self.assertNotIn("irdigest", str(rec["google"]["notes"]))


if __name__ == "__main__":
    unittest.main()
