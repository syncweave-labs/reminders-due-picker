#!/usr/bin/env python3
"""Move the installed standalone bridge into the app, then retire it after proof.

Preparation keeps every legacy file until a newer successful app sync is proven.
Source repositories are deliberately outside the cleanup scope.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def write_private(path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    path.chmod(0o600)


def locations(home):
    return (home / ".config/icloud-reminders-google-sync",
            home / "Library/Application Support/RemindersDuePicker/GoogleSync")


def prepare(home, stop_agent=True):
    old, new = locations(home)
    if not old.exists():
        print("No legacy installation to migrate.")
        return False
    if new.exists():
        if (new / "migration.json").exists():
            print("Existing migration preserved; no state overwritten.")
            return True
        raise RuntimeError("App sync data already exists; refusing to overwrite it.")
    if old.is_symlink():
        raise RuntimeError("Legacy config is a symlink; refusing migration.")
    config = json.loads((old / "config.json").read_text())
    # Prove required inputs are readable before stopping a working installation.
    for key in ("state_path", "token_path", "credentials_path"):
        path = Path(config[key]).expanduser()
        if not path.is_file():
            raise RuntimeError(f"Required migration input is missing: {key}")
        json.loads(path.read_text())
    agent = home / "Library/LaunchAgents/com.icloud-reminders-google-sync.plist"
    if stop_agent and agent.exists():
        result = subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(agent)], capture_output=True)
        if result.returncode:
            loaded = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/com.icloud-reminders-google-sync"], capture_output=True)
            if loaded.returncode == 0:
                raise RuntimeError("Could not stop the legacy sync agent.")
    new.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    staged = Path(tempfile.mkdtemp(prefix=".GoogleSync-migrate-", dir=new.parent))
    try:
        for key, filename in (("credentials_path", "credentials.json"), ("token_path", "token.json"),
                              ("state_path", "state.json"), ("status_path", "status.json"),
                              ("adc_credentials_path", "adc.json")):
            original = Path(config.get(key, str(old / filename))).expanduser()
            if original.exists():
                if original.is_symlink():
                    raise RuntimeError(f"Refusing linked migration input: {key}")
                shutil.copyfile(original, staged / filename)
                (staged / filename).chmod(0o600)
            config[key] = str(new / filename)
        config.update(reminders_source="eventkit", auto_reauth_browser=False,
                      macos_notifications=False)
        # Legacy Swift source paths are irrelevant: the signed app does EventKit IPC.
        config.pop("reminders_exporter_path", None)
        config.pop("reminders_apply_path", None)
        write_private(staged / "config.json", config)
        state = json.loads((staged / "state.json").read_text())
        write_private(staged / "migration.json", {
            "version": 1, "migrated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "state_sha256": hashlib.sha256((staged / "state.json").read_bytes()).hexdigest(),
            "task_mapping_count": len(state.get("tasks", {})),
            "legacy_home": str(home), "cleanup_complete": False,
        })
        staged.rename(new)
    except BaseException:
        shutil.rmtree(staged, ignore_errors=True)
        if stop_agent and agent.exists():
            subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(agent)], capture_output=True)
        raise
    if stop_agent:
        subprocess.run(["defaults", "write", "com.icloud-reminders-google-sync.due-picker", "GoogleSyncEnabled", "-bool", "true"], check=True)
    print("Legacy credentials and mappings migrated; legacy files retained until app sync succeeds.")
    return True


def cleanup(home):
    old, new = locations(home)
    manifest = json.loads((new / "migration.json").read_text())
    if manifest.get("legacy_home") != str(home):
        raise RuntimeError("Migration home mismatch.")
    status = json.loads((new / "status.json").read_text())
    config = json.loads((new / "config.json").read_text())
    success = dt.datetime.fromisoformat(status.get("last_success_at", "").replace("Z", "+00:00"))
    migrated = dt.datetime.fromisoformat(manifest["migrated_at"])
    if status.get("state") != "ok" or success <= migrated or not config.get("verify_title_due_after_sync"):
        raise RuntimeError("A new successful, consistency-verified app sync is required before cleanup.")
    loaded = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/com.icloud-reminders-google-sync"], capture_output=True)
    if loaded.returncode == 0:
        raise RuntimeError("Legacy agent is still loaded; refusing cleanup.")
    runtime = home / ".local/share/icloud-reminders-google-sync"
    # Remove only known legacy entrypoints with their exact expected targets.
    for folder in (Path("/Applications"), home / "Applications", home / "Desktop"):
        if not folder.exists():
            continue
        for path in folder.iterdir():
            if path.is_symlink() and path.name.endswith(".command"):
                target = Path(os.readlink(path))
                if target == runtime / "current/google-tasks-manager.command":
                    path.unlink()
    agent = home / "Library/LaunchAgents/com.icloud-reminders-google-sync.plist"
    agent.unlink(missing_ok=True)
    for path in (old, runtime, home / "Library/Logs/icloud-reminders-google-sync"):
        if path.is_symlink():
            raise RuntimeError("Refusing cleanup of a linked legacy directory.")
        if path.exists():
            shutil.rmtree(path)
    manifest["cleanup_complete"] = True
    manifest["cleaned_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
    write_private(new / "migration.json", manifest)
    print("Removed legacy command shortcuts, LaunchAgent, runtime releases, configuration, backups and logs.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "cleanup"])
    args = parser.parse_args()
    (prepare if args.action == "prepare" else cleanup)(Path.home())
