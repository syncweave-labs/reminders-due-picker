#!/usr/bin/env bash
# Self-test for the installer's legacy-bundle and login-agent migration. It runs
# scripts/install-due-picker-app.sh --migrate-only against throwaway temp dirs
# and NEVER touches the real /Applications, ~/Applications, ~/Library/LaunchAgents
# or the Dock: every path is injected through DUE_PICKER_* environment variables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALLER="${SCRIPT_DIR}/install-due-picker-app.sh"
BUNDLE_ID="com.icloud-reminders-google-sync.due-picker"
LEGACY_APP_NAME="미리알림 날짜.app"
LOGIN_LABEL="com.icloud-reminders-google-sync.due-picker.login"
NEW_APP_NAME="Reminders Due Picker.app"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/due-picker-migrate.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

make_bundle() {
  # make_bundle DIR NAME BUNDLE_ID
  local path="$1/$2"
  mkdir -p "${path}/Contents/MacOS"
  cat >"${path}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$3</string>
<key>CFBundleExecutable</key><string>DuePicker</string>
</dict></plist>
PLIST
  printf '#!/bin/sh\n' >"${path}/Contents/MacOS/DuePicker"
  chmod 0755 "${path}/Contents/MacOS/DuePicker"
}

SYS_APPS="${TMP_ROOT}/Applications"         # stands in for /Applications
HOME_APPS="${TMP_ROOT}/home/Applications"   # stands in for ~/Applications
BACKUP_ROOT="${TMP_ROOT}/state/backups"
AGENTS_DIR="${TMP_ROOT}/LaunchAgents"
mkdir -p "$SYS_APPS" "$HOME_APPS" "$AGENTS_DIR"

# The freshly "installed" new bundle lives in SYS_APPS under the new name.
make_bundle "$SYS_APPS" "$NEW_APP_NAME" "$BUNDLE_ID"
NEW_BUNDLE="${SYS_APPS}/${NEW_APP_NAME}"
# The installer canonicalizes the bundle path with `pwd -P`; match it so the
# rewritten login-agent path comparison does not trip over /private symlinks.
NEW_BUNDLE_REAL="$(cd "$NEW_BUNDLE" && pwd -P)"
NEW_EXE="${NEW_BUNDLE_REAL}/Contents/MacOS/DuePicker"

# A legacy bundle with the matching id (must be MOVED to a backup, not deleted).
make_bundle "$SYS_APPS" "$LEGACY_APP_NAME" "$BUNDLE_ID"
# A legacy-named bundle in ~/Applications with a DIFFERENT id (must be LEFT alone).
make_bundle "$HOME_APPS" "$LEGACY_APP_NAME" "com.example.not-ours"

# Full-structure assertions on the migrated login agent. These read the ENTIRE
# ProgramArguments array and the complete key set, not just index 0: the bug
# this test guards against left a 4-element [new, --background, old, --background]
# array that an index-0-only check would have called healthy.
PY="${SYNC_PYTHON:-$(command -v python3)}"
if [ -x /opt/homebrew/bin/python3 ]; then PY=/opt/homebrew/bin/python3; fi

# program_arguments PLIST -> the ProgramArguments array, one NUL-free element per
# line prefixed with its index, so a mismatch in count or order is visible.
program_arguments() {
  "$PY" - "$1" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    d = plistlib.load(fh)
args = d.get("ProgramArguments")
if not isinstance(args, list):
    print("NOT-AN-ARRAY"); sys.exit(0)
for i, a in enumerate(args):
    print(f"{i}:{a}")
PYEOF
}

# plist_keys PLIST -> the sorted top-level key set on one line.
plist_keys() {
  "$PY" - "$1" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    d = plistlib.load(fh)
print(",".join(sorted(d.keys())))
PYEOF
}

assert_agent_exact() {
  # assert_agent_exact PLIST EXPECTED_EXE  — the whole array is [EXE, --background],
  # the key set is exactly the canonical four, and other keys kept their values.
  local plist="$1" expected_exe="$2"
  local got_args want_args got_keys
  got_args="$(program_arguments "$plist")"
  want_args="$(printf '0:%s\n1:--background' "$expected_exe")"
  [ "$got_args" = "$want_args" ] \
    || fail "ProgramArguments is not exactly [${expected_exe}, --background]; got:"$'\n'"$got_args"
  got_keys="$(plist_keys "$plist")"
  [ "$got_keys" = "Label,ProcessType,ProgramArguments,RunAtLoad" ] \
    || fail "key set is '$got_keys', expected exactly Label,ProcessType,ProgramArguments,RunAtLoad"
  [ "$(plutil -extract Label raw -o - "$plist")" = "$LOGIN_LABEL" ] || fail "Label not preserved"
  [ "$(plutil -extract RunAtLoad raw -o - "$plist")" = "true" ] || fail "RunAtLoad not preserved"
  [ "$(plutil -extract ProcessType raw -o - "$plist")" = "Interactive" ] || fail "ProcessType not preserved"
  local mode
  mode="$(stat -f '%Lp' "$plist")"
  [ "$mode" = "600" ] || fail "login agent mode is $mode, expected 600"
}

# A login agent pointing at the OLD executable path, with the LEGACY 2-element
# ProgramArguments array [old-exe, --background] exactly as macOS writes it. This
# is the fixture that reproduced the index-0-replace insertion bug.
OLD_EXE="/Users/x/Applications/${LEGACY_APP_NAME}/Contents/MacOS/DuePicker"
AGENT="${AGENTS_DIR}/${LOGIN_LABEL}.plist"
write_legacy_agent() {
  cat >"$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${LOGIN_LABEL}</string>
<key>ProgramArguments</key><array><string>${OLD_EXE}</string><string>--background</string></array>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
  chmod 0644 "$AGENT"
}
write_legacy_agent

# Sanity: the fixture really is the legacy 2-element array before migration.
[ "$(program_arguments "$AGENT")" = "$(printf '0:%s\n1:--background' "$OLD_EXE")" ] \
  || fail "legacy fixture is not the expected 2-element array"

run_migrate() {
  DUE_PICKER_LEGACY_DIRS="${SYS_APPS}:${HOME_APPS}" \
  DUE_PICKER_BACKUP_ROOT="$BACKUP_ROOT" \
  DUE_PICKER_LAUNCHAGENTS_DIR="$AGENTS_DIR" \
    bash "$INSTALLER" --migrate-only "$NEW_BUNDLE" >/dev/null
}

run_migrate

# 1) Matching legacy bundle moved out of /Applications (temp) ...
[ ! -e "${SYS_APPS}/${LEGACY_APP_NAME}" ] || fail "matching legacy bundle was not moved"
# ... into a timestamped backup (not deleted).
BACKED_UP="$(find "$BACKUP_ROOT" -maxdepth 2 -name "$LEGACY_APP_NAME" -type d | head -n1)"
[ -n "$BACKED_UP" ] || fail "legacy bundle not found in the backup root"
[ -f "${BACKED_UP}/Contents/Info.plist" ] || fail "backed-up bundle is incomplete"
pass "matching legacy bundle moved to backup (not deleted)"

# Backup root and the timestamped dir are mode 0700.
MODE_ROOT="$(stat -f '%Lp' "$BACKUP_ROOT")"
[ "$MODE_ROOT" = "700" ] || fail "backup root mode is $MODE_ROOT, expected 700"
MODE_STAMP="$(stat -f '%Lp' "$(dirname "$BACKED_UP")")"
[ "$MODE_STAMP" = "700" ] || fail "backup timestamp dir mode is $MODE_STAMP, expected 700"
pass "backup directories are mode 0700"

# 2) Legacy bundle with a different id is left alone with a warning.
[ -d "${HOME_APPS}/${LEGACY_APP_NAME}" ] || fail "foreign-id legacy bundle was moved"
pass "foreign-id legacy bundle left alone"

# 3) The new bundle is still in place.
[ -d "$NEW_BUNDLE" ] || fail "new bundle was disturbed"
pass "new bundle untouched"

# 4) Login agent rewritten to EXACTLY [new-exe, --background]; the other keys
#    preserved; mode 0600. The whole array is checked, so the historical
#    4-element [new, --background, old, --background] result is a failure.
assert_agent_exact "$AGENT" "$NEW_EXE"
pass "login agent rewritten to exactly [new-exe, --background], keys preserved, mode 0600"

# 4b) Idempotent on re-run: migrating again over the already-migrated agent
#     leaves exactly [new-exe, --background] — it does not append or duplicate.
#     No legacy bundle is re-added here; migrate_login_agent runs every time and
#     is what this case exercises.
run_migrate
assert_agent_exact "$AGENT" "$NEW_EXE"
pass "re-running migration is idempotent (array stays [new-exe, --background])"

# 4c) A stale legacy 2-element array written fresh then migrated once more also
#     lands on exactly [new-exe, --background] (array replaced, never extended).
write_legacy_agent
run_migrate
assert_agent_exact "$AGENT" "$NEW_EXE"
pass "legacy 2-element fixture migrates to exactly [new-exe, --background]"

# 5) An absent login agent is never created.
rm -f "$AGENT"
make_bundle "$SYS_APPS" "$LEGACY_APP_NAME" "$BUNDLE_ID" # re-add so there is work
run_migrate
[ ! -e "$AGENT" ] || fail "absent login agent was created"
pass "absent login agent not created"

# 6) The real system paths were never touched (we only used temp dirs).
printf 'Installer migration self-test passed.\n'
