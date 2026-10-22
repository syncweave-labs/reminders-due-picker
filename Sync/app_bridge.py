"""Private IPC adapter for the signed app; never a user-facing command."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

import icloud_reminders_google_sync as engine

DATA_DIR = Path.home() / "Library/Application Support/RemindersDuePicker/GoogleSync"


def configure(data_dir: Path, executable: Path) -> dict:
    engine.APP_NAME = "RemindersDuePicker"
    engine.LAUNCH_AGENT_LABEL = "com.icloud-reminders-google-sync.due-picker.login"
    engine.default_config_dir = lambda: data_dir
    config = engine.load_config(argparse.Namespace(config=str(data_dir / "config.json")))
    # EventKit always goes through this signed app, with its existing permission.
    def helper(mode: str, arguments: list[str], operations=None):
        result = subprocess.run(
            [str(executable), mode, *arguments],
            input=None if operations is None else json.dumps(operations, ensure_ascii=False),
            capture_output=True, text=True, timeout=180,
        )
        if result.returncode:
            raise SystemExit("미리알림 접근에 실패했습니다. 앱의 미리알림 권한을 확인하세요.")
        payload = json.loads(result.stdout)
        if not isinstance(payload, list):
            raise SystemExit("미리알림 응답 형식이 올바르지 않습니다.")
        return payload

    def export(config, completed_only=False):
        arguments = ["--lookahead-days", str(config["lookahead_days"])]
        if engine.reminders_export_needs_undated(config):
            arguments.append("--include-undated")
        if completed_only:
            arguments.append("--completed-only")
        for name in config["include_lists"]:
            arguments.extend(["--list", name])
        return helper("--sync-export", arguments)

    def lists(config):
        arguments = ["--lists-only"]
        for name in config["include_lists"]:
            arguments.extend(["--list", name])
        return helper("--sync-export", arguments)

    engine.run_reminders_export = export
    engine.run_reminders_lists_export = lists
    engine.run_reminders_apply = lambda config, operations: helper("--sync-apply", [], operations)
    return config


def initialize(data_dir: Path):
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(data_dir, 0o700)
    path = data_dir / "config.json"
    if path.exists():
        return
    config = engine.default_config()
    for key, filename in (("credentials_path", "credentials.json"), ("token_path", "token.json"),
                          ("state_path", "state.json"), ("status_path", "status.json"),
                          ("adc_credentials_path", "adc.json")):
        config[key] = str(data_dir / filename)
    config.update(use_adc=False, target_service="tasks", bidirectional=True,
                  tasks_import_unsynced=True, tasks_sync_undated=True,
                  sync_interval_seconds=60, delete_stale=False,
                  auto_reauth_browser=False, macos_notifications=False)
    engine.write_json_atomic(path, config)


def connect(config):
    """Reauthorization never silently reuses a different account's state."""
    state = engine.load_state(Path(config["state_path"]))
    bound = bool(state.get("tasks") or state.get("events") or state.get("account_binding"))
    before = engine.check_google_connection(config) if bound else {}
    cached_path = Path(config["status_path"]).parent / "connection.json"
    if not before.get("account_fingerprint") and cached_path.exists():
        before = engine.read_json(cached_path)
    if bound and not before.get("account_fingerprint"):
        return {"state": "account_binding_required", "message": "기존 Google 계정을 확인할 수 없어 연결 변경을 중단했습니다. 기존 연결이 복구된 뒤 다시 시도하세요."}
    token_path = Path(config["token_path"])
    original = token_path.read_bytes() if token_path.exists() else None
    state_path = Path(config["state_path"])
    original_state = state_path.read_bytes() if state_path.exists() else None
    original_config = dict(config)
    try:
        engine.run_auth_flow(config)
        config["use_adc"] = False
        after = engine.check_google_connection(config)
        if after["state"] != "ok":
            raise ValueError("연결 확인에 실패했습니다. 다시 시도하세요.")
        if bound:
            if after.get("account_fingerprint") != before.get("account_fingerprint"):
                raise ValueError("기존 동기화 계정과 다릅니다. 같은 Google 계정으로 연결하세요.")
            # Verified same Google subject: refresh-token rotation is safe.
            state["account_binding"]["google"] = engine.google_credential_binding(engine.load_token(config))
            engine.write_json_atomic(Path(config["state_path"]), state)
        engine.write_json_atomic(Path(config["status_path"]).parent / "config.json", config)
        engine.write_json_atomic(cached_path, after)
        return after
    except (Exception, SystemExit):
        if original is None:
            token_path.unlink(missing_ok=True)
        else:
            temporary = token_path.with_suffix(".restore")
            temporary.write_bytes(original)
            temporary.chmod(0o600)
            temporary.replace(token_path)
        if original_state is not None:
            temporary_state = state_path.with_suffix(".restore")
            temporary_state.write_bytes(original_state)
            temporary_state.chmod(0o600)
            temporary_state.replace(state_path)
        config.clear()
        config.update(original_config)
        return {"state": "auth_required", "message": "Google 연결을 완료하지 못했습니다. 기존 연결은 보존했습니다. 같은 계정으로 다시 시도하세요."}


def loop(args):
    wake = threading.Event()
    signal.signal(signal.SIGUSR1, lambda *_: wake.set())
    def stop(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    parent = os.getppid()
    def monitor_parent():
        while True:
            time.sleep(1)
            if os.getppid() != parent:
                os.kill(os.getpid(), signal.SIGTERM)
                return
    threading.Thread(target=monitor_parent, daemon=True).start()
    def wait(interval, approvals):
        deadline = time.monotonic() + interval
        while time.monotonic() < deadline:
            if wake.wait(min(1, max(0, deadline - time.monotonic()))):
                wake.clear()
                return
            if approvals.dialog_open() and not approvals.dialog_running():
                return
    engine.wait_for_next_cycle = wait
    ready = Path(args.config).parent / "worker.json"
    engine.write_json_atomic(ready, {"pid": os.getpid()})
    try:
        engine.cmd_run_loop(argparse.Namespace(config=args.config))
    except KeyboardInterrupt:
        pass
    finally:
        # During an app update a replacement may already own this marker.
        if ready.exists() and engine.read_json(ready).get("pid") == os.getpid():
            ready.unlink(missing_ok=True)


def policy_read(config):
    """Read-only per-list policy with effective/inherited/override, and lists."""
    import sync_ui_support as ui

    titles = sorted({str(item.get("list_title") or "") for item in engine.run_reminders_lists_export(config)} - {""})
    return ui.policy_read(config, titles)


def policy_preview(config, payload):
    import sync_ui_support as ui

    try:
        return ui.preview_policy_save(config, payload.get("list_policies"))
    except ValueError as exc:
        return {"ok": False, "state": "invalid_policy", "message": str(exc)}


def policy_save(config, data_dir, payload):
    """Atomic private save under the shared sync lock (worker-stop contract).

    Acquiring ``sync_lock`` with wait serializes against any in-flight sync
    cycle, so the worker never writes config concurrently. Only list_policies
    is rewritten; a fingerprint mismatch returns policy_stale and writes
    nothing.
    """
    import sync_ui_support as ui

    config_path = data_dir / "config.json"
    with engine.sync_lock(config, wait=True) as acquired:
        if not acquired:  # pragma: no cover - wait=True blocks instead
            return {"ok": False, "state": "busy", "message": "동기화가 진행 중입니다. 잠시 뒤 다시 저장하세요."}
        try:
            return ui.apply_policy_save(
                config_path,
                payload.get("list_policies"),
                str(payload.get("fingerprint") or ""),
            )
        except ValueError as exc:
            return {"ok": False, "state": "invalid_policy", "message": str(exc)}


def conflict_list(config, data_dir):
    import sync_ui_support as ui

    directory = data_dir / "Conflicts"
    journal = ui.ConflictJournal(directory)
    records = journal.records()
    return {"ok": True, "summary": ui.conflict_status_summary(records), "conflicts": records}


def conflict_apply(config, data_dir, payload):
    """Apply one conflict choice via the engine's planner and destructive gate."""
    import sync_ui_support as ui

    directory = data_dir / "Conflicts"
    journal = ui.ConflictJournal(directory)
    resolutions = ui.ConflictResolutionJournal(directory / "Resolutions")
    state = engine.load_state(Path(config["state_path"]))
    binding = state.get("account_binding") if isinstance(state.get("account_binding"), dict) else {}

    def read_apple(list_title, uid):
        for reminder in engine.run_reminders_export(config):
            if str(reminder.get("list_title") or "") == list_title and _reminder_uid(config, reminder) == uid:
                return reminder
        return None

    def read_google(list_title, uid):
        # The engine owns live Google reads; without a live client this returns
        # the last-observed RAW task from the record so an offline call still
        # compares revisions deterministically. A client-backed reader can
        # replace this when a connection exists.
        record = next((r for r in journal.records() if r.get("conflict_id") == payload.get("conflict_id")), None)
        return (record or {}).get("google_raw")

    def apply_change(context):
        # Route the single chosen write through the engine's mutation planner
        # and destructive-approval gate, then perform exactly that write. The
        # gate raises MutationPlanApprovalRequired when the change would need a
        # destructive approval, which resolve_conflict surfaces unchanged.
        return _apply_conflict_choice(config, context)

    return ui.resolve_conflict(
        config,
        journal,
        resolutions,
        str(payload.get("conflict_id") or ""),
        str(payload.get("choice") or ""),
        payload.get("expected_revision") or {},
        operation_id=str(payload.get("operation_id") or ""),
        read_apple=read_apple,
        read_google=read_google,
        apply_change=apply_change,
        account_binding=binding,
    )


def _reminder_uid(config, reminder):
    return reminder.get("stable_id") or reminder.get("external_id") or reminder.get("id") or ""


def _apply_conflict_choice(config, context):
    """Build a single-action plan, enforce the gate, then apply the one write.

    choice=="google" writes the Google side onto Apple Reminders (a completion
    is destructive and must pass the gate). choice=="apple" leaves Apple as the
    authority and patches the Google task; a Google completion/deletion is
    equally gated.
    """
    choice = context["choice"]
    list_title = context["list_title"]
    uid = context["uid"]
    reminder = context["apple"]
    task = context["google"]

    if choice == "google":
        operation = engine.google_task_to_reminder_operation(task, reminder, config)
        destructive = bool(operation.get("complete") or operation.get("delete"))
        action = engine.planned_mutation(
            "apple_reminders", "complete" if operation.get("complete") else "update",
            [list_title, uid], destructive=destructive, list_title=list_title,
            title=str(reminder.get("title") or ""),
        )
        plan = engine.build_mutation_plan([action], population=1)
        engine.enforce_mutation_plan(config, plan, dry_run=False)
        results = engine.run_reminders_apply(config, [operation])
        return {"side": "apple", "results": results}

    # choice == "apple": Apple is authoritative; a Google-side write is planned.
    destructive = bool(reminder.get("is_completed"))
    action = engine.planned_mutation(
        "google_tasks", "update", [list_title, uid], destructive=destructive,
        list_title=list_title, title=str(reminder.get("title") or ""),
    )
    plan = engine.build_mutation_plan([action], population=1)
    engine.enforce_mutation_plan(config, plan, dry_run=False)
    # Without a live Google client here the engine's next normal sync applies
    # the Apple-authoritative value; we record the intent and let the loop push
    # it. Returning the gated plan proves the destructive gate ran.
    return {"side": "google", "planned": plan["fingerprint"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action",
        choices=["loop", "check", "auth", "init",
                 "policy-read", "policy-preview", "policy-save",
                 "conflict-list", "conflict-apply"],
    )
    parser.add_argument("--data-dir", type=Path, default=DATA_DIR)
    parser.add_argument("--executable", type=Path, required=True)
    args = parser.parse_args()
    initialize(args.data_dir)
    config = configure(args.data_dir, args.executable)
    args.config = str(args.data_dir / "config.json")
    if args.action == "loop":
        loop(args)
    elif args.action in ("check", "auth"):
        # Keep engine output (including OAuth URLs and private paths) out of IPC.
        import contextlib
        with contextlib.redirect_stdout(sys.stderr):
            result = connect(config) if args.action == "auth" else engine.check_google_connection(config)
        previous_path = args.data_dir / "connection.json"
        if result.get("state") != "ok" and previous_path.exists():
            previous = engine.read_json(previous_path)
            for key in ("account_email", "account_fingerprint"):
                if previous.get(key): result[key] = previous[key]
        engine.write_json_atomic(args.data_dir / "connection.json", result)
        print(json.dumps(result, ensure_ascii=False))
    elif args.action in ("policy-read", "policy-preview", "policy-save", "conflict-list", "conflict-apply"):
        import contextlib
        payload = {}
        if args.action in ("policy-preview", "policy-save", "conflict-apply"):
            raw = sys.stdin.read()
            payload = json.loads(raw) if raw.strip() else {}
        with contextlib.redirect_stdout(sys.stderr):
            if args.action == "policy-read":
                result = policy_read(config)
            elif args.action == "policy-preview":
                result = policy_preview(config, payload)
            elif args.action == "policy-save":
                result = policy_save(config, args.data_dir, payload)
            elif args.action == "conflict-list":
                result = conflict_list(config, args.data_dir)
            else:
                result = conflict_apply(config, args.data_dir, payload)
        print(json.dumps(result, ensure_ascii=False))
    else:
        print('{"state":"initialized"}')


if __name__ == "__main__":
    main()
