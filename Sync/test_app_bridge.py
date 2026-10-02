import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock

import app_bridge as bridge
import icloud_reminders_google_sync as engine

spec = importlib.util.spec_from_file_location("migration", Path(__file__).parents[1] / "scripts/migrate-google-sync.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class AppBridgeTests(unittest.TestCase):
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


if __name__ == "__main__": unittest.main()
