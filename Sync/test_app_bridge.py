import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
import os
import signal
import time
from unittest.mock import patch, Mock

import app_bridge as bridge
import icloud_reminders_google_sync as engine

spec = importlib.util.spec_from_file_location("migration", Path(__file__).parents[1] / "scripts/migrate-google-sync.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class AppBridgeTests(unittest.TestCase):
    def test_sync_now_wakes_a_ready_worker_without_restarting_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            code = '''import argparse, time
import app_bridge as bridge
class Approvals:
    def dialog_open(self): return False
def cycle(args):
    bridge.engine.wait_for_next_cycle(300, Approvals())
bridge.engine.cmd_run_loop = cycle
bridge.loop(argparse.Namespace(config=__import__('sys').argv[1]))
'''
            process = subprocess.Popen([sys.executable, "-B", "-c", code, str(Path(tmp) / "config.json")], cwd=Path(__file__).parent)
            try:
                ready = Path(tmp) / "worker.json"
                deadline = time.monotonic() + 10
                while not ready.exists() and time.monotonic() < deadline:
                    if process.poll() is not None: self.fail("worker exited before readiness")
                    time.sleep(0.02)
                self.assertEqual(json.loads(ready.read_text())["pid"], process.pid)
                os.kill(process.pid, signal.SIGUSR1)
                self.assertEqual(process.wait(timeout=5), 0)
                self.assertFalse(ready.exists())
            finally:
                if process.poll() is None: process.terminate(); process.wait(timeout=5)

    def test_initial_setup_disables_deletions_and_stays_app_owned(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "data"
            bridge.initialize(folder)
            config = json.loads((folder / "config.json").read_text())
            self.assertFalse(config["delete_stale"])
            self.assertFalse(config["use_adc"])
            self.assertTrue(config["bidirectional"])
            self.assertEqual(config["state_path"], str(folder / "state.json"))
            self.assertEqual((folder / "config.json").stat().st_mode & 0o777, 0o600)
            self.assertEqual(folder.stat().st_mode & 0o777, 0o700)

    def test_signed_eventkit_ipc_uses_stdin_not_argv_for_writes(self):
        keys = ["APP_NAME", "LAUNCH_AGENT_LABEL", "default_config_dir", "run_reminders_export",
                "run_reminders_lists_export", "run_reminders_apply"]
        originals = {key: getattr(engine, key) for key in keys}
        try:
            with tempfile.TemporaryDirectory() as tmp, patch.object(bridge.subprocess, "run") as run:
                run.return_value = Mock(returncode=0, stdout="[]")
                config = bridge.configure(Path(tmp), Path("/Applications/App.app/Contents/MacOS/DuePicker"))
                private = [{"title": "PRIVATE SAMPLE", "create": True}]
                engine.run_reminders_apply(config, private)
                args, kwargs = run.call_args
                self.assertEqual(args[0][-1], "--sync-apply")
                self.assertNotIn("PRIVATE SAMPLE", " ".join(args[0]))
                self.assertEqual(json.loads(kwargs["input"]), private)
                engine.run_reminders_export(config, completed_only=True)
                self.assertIn("--completed-only", run.call_args.args[0])
                engine.run_reminders_lists_export(config)
                self.assertIn("--lists-only", run.call_args.args[0])
        finally:
            for key, value in originals.items(): setattr(engine, key, value)

    def test_migration_preserves_mapping_and_secrets_but_rewrites_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            old, new = migration.locations(home)
            old.mkdir(parents=True)
            config = engine.default_config()
            for key, filename, payload in (
                ("state_path", "state.json", {"tasks": {"id": {"task_id": "existing"}}}),
                ("token_path", "token.json", {"refresh_token": "synthetic"}),
                ("credentials_path", "credentials.json", {"installed": {"client_id": "synthetic"}}),
            ):
                config[key] = str(old / filename)
                migration.write_private(old / filename, payload)
            config["status_path"] = str(old / "status.json")
            config["adc_credentials_path"] = str(old / "missing-adc.json")
            migration.write_private(old / "config.json", config)
            before = (old / "state.json").read_bytes()
            self.assertTrue(migration.prepare(home, stop_agent=False))
            self.assertEqual((new / "state.json").read_bytes(), before)
            self.assertTrue(old.exists())
            migrated = json.loads((new / "config.json").read_text())
            self.assertEqual(migrated["state_path"], str(new / "state.json"))
            self.assertNotIn("reminders_apply_path", migrated)
            migration.prepare(home, stop_agent=False)
            self.assertEqual((new / "state.json").read_bytes(), before)

    def test_cleanup_refuses_old_success_and_keeps_legacy_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            old, new = migration.locations(home)
            old.mkdir(parents=True); new.mkdir(parents=True)
            migration.write_private(new / "migration.json", {"legacy_home": str(home), "migrated_at": "2026-10-02T00:00:00+00:00"})
            migration.write_private(new / "status.json", {"state": "ok", "last_success_at": "2026-10-01T00:00:00+00:00"})
            migration.write_private(new / "config.json", {"verify_title_due_after_sync": True})
            with self.assertRaises(RuntimeError): migration.cleanup(home)
            self.assertTrue(old.exists())

    def test_reconnect_different_account_restores_original_token(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            config = {"state_path": str(folder / "state.json"), "token_path": str(folder / "token.json"),
                      "status_path": str(folder / "status.json"), "use_adc": False}
            engine.write_json_atomic(folder / "state.json", {"tasks": {"x": {}}, "account_binding": {"google": "old"}})
            (folder / "token.json").write_bytes(b'{"refresh_token":"original"}')
            before = (folder / "token.json").read_bytes()
            def auth(_): (folder / "token.json").write_bytes(b'{"refresh_token":"different"}')
            with patch.object(engine, "run_auth_flow", side_effect=auth), patch.object(engine, "check_google_connection", side_effect=[
                {"state": "ok", "account_fingerprint": "first"}, {"state": "ok", "account_fingerprint": "other"}]) as check:
                result = bridge.connect(config)
            self.assertEqual(result["state"], "auth_required")
            self.assertEqual((folder / "token.json").read_bytes(), before)
            self.assertEqual(engine.read_json(folder / "state.json")["account_binding"]["google"], "old")

    def test_reconnect_same_account_updates_binding(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            config = {"state_path": str(folder / "state.json"), "token_path": str(folder / "token.json"),
                      "status_path": str(folder / "status.json"), "use_adc": True}
            engine.write_json_atomic(folder / "state.json", {"tasks": {"x": {}}, "account_binding": {"google": "old"}})
            engine.write_json_atomic(folder / "token.json", {"refresh_token": "original"})
            with patch.object(engine, "run_auth_flow"), patch.object(engine, "check_google_connection", return_value={"state": "ok", "account_fingerprint": "same"}), patch.object(engine, "load_token", return_value={"refresh_token": "new"}):
                result = bridge.connect(config)
            self.assertEqual(result["state"], "ok")
            self.assertEqual(engine.read_json(folder / "state.json")["account_binding"]["google"], engine.google_credential_binding({"refresh_token": "new"}))
            self.assertFalse(engine.read_json(folder / "config.json")["use_adc"])


class U09BridgeTests(unittest.TestCase):
    """U09 policy and conflict IPC: narrow actions, no arbitrary paths/keys,
    worker-stop/lock contract, planner-routed resolution with the gate."""

    def _config(self, tmp):
        config = engine.default_config()
        config.update(
            state_path=str(tmp / "state.json"),
            status_path=str(tmp / "status.json"),
            bidirectional=True, delete_stale=False, conflict_policy="skip",
            list_policies={}, include_lists=[],
            max_destructive_changes=0, max_destructive_ratio=0.0,
        )
        return config

    def test_policy_read_uses_signed_lists_export_and_shows_effective(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = self._config(tmp)
            with patch.object(engine, "run_reminders_lists_export", return_value=[{"list_title": "Work"}, {"list_title": "Home"}]):
                payload = bridge.policy_read(config)
            titles = {row["list_title"] for row in payload["lists"]}
            self.assertEqual(titles, {"Work", "Home"})
            self.assertTrue(payload["name_keyed"])

    def test_policy_save_is_serialized_by_the_sync_lock_and_writes_config_only(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = self._config(tmp)
            path = tmp / "config.json"
            engine.write_json_atomic(path, config)
            import sync_ui_support as ui
            fp = ui.config_fingerprint(config)
            result = bridge.policy_save(config, tmp, {"list_policies": {"Work": {"direction": "apple_to_google"}}, "fingerprint": fp})
            self.assertTrue(result["ok"])
            saved = json.loads(path.read_text())
            self.assertEqual(saved["list_policies"], {"Work": {"direction": "apple_to_google"}})
            self.assertFalse((tmp / "state.json").exists())

    def test_policy_save_rejects_unknown_keys(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = self._config(tmp)
            engine.write_json_atomic(tmp / "config.json", config)
            import sync_ui_support as ui
            result = bridge.policy_save(config, tmp, {"list_policies": {"Work": {"evil": 1}}, "fingerprint": ui.config_fingerprint(config)})
            self.assertFalse(result["ok"])
            self.assertEqual(result["state"], "invalid_policy")

    def test_conflict_apply_routes_through_the_destructive_gate(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = self._config(tmp)
            engine.write_json_atomic(tmp / "config.json", config)
            engine.write_json_atomic(tmp / "state.json", {"account_binding": {"version": 1, "apple": "a", "google": "g"}})
            import sync_ui_support as ui
            reminder = {"id": "u1", "stable_id": "u1", "external_id": "u1", "list_title": "Work",
                        "title": "R", "notes": "", "due_date": "2026-10-20", "is_completed": False,
                        "modified_at": "2026-10-20T09:00:00Z"}
            # A completed Google task -> writing it to Apple is a completion =
            # destructive, so the (tight) gate must block it, not bypass it.
            task = {"id": "g1", "title": "R2", "notes": "", "due": "2026-10-22T00:00:00Z", "status": "completed", "etag": "e1"}
            journal = ui.ConflictJournal(tmp / "Conflicts")
            rec = ui.build_conflict_record({"apple": "a", "google": "g"}, "Work", "u1", reminder, task)
            journal.observe(rec)

            enforce_calls = []
            real_enforce = engine.enforce_mutation_plan
            def spy_enforce(cfg, plan, **kw):
                enforce_calls.append(plan)
                return real_enforce(cfg, plan, **kw)
            with patch.object(engine, "run_reminders_export", return_value=[reminder]), \
                 patch.object(engine, "enforce_mutation_plan", side_effect=spy_enforce), \
                 patch.object(engine, "write_sync_status"):
                payload = {"conflict_id": rec["conflict_id"], "choice": "google",
                           "expected_revision": {"apple": reminder["modified_at"], "google": task["etag"]},
                           "operation_id": "op-bridge"}
                result = bridge.conflict_apply(config, tmp, payload)
            # The gate ran (plan built) and blocked the destructive completion.
            self.assertTrue(enforce_calls)
            self.assertEqual(result["state"], "blocked_mutation_plan")
            # The conflict stays open because nothing was applied.
            self.assertIn(rec["conflict_id"], {r["conflict_id"] for r in ui.ConflictJournal(tmp / "Conflicts").records()})

    def test_conflict_list_returns_counts_and_records(self):
        with tempfile.TemporaryDirectory() as t:
            tmp = Path(t)
            config = self._config(tmp)
            import sync_ui_support as ui
            journal = ui.ConflictJournal(tmp / "Conflicts")
            journal.observe(ui.build_conflict_record({"apple": "a", "google": "g"}, "Work", "u1",
                {"title": "x", "modified_at": "m"}, {"title": "y", "etag": "e"}))
            payload = bridge.conflict_list(config, tmp)
            self.assertTrue(payload["ok"])
            self.assertEqual(payload["summary"]["total"], 1)
            self.assertEqual(len(payload["conflicts"]), 1)


if __name__ == "__main__": unittest.main()
