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

# A login agent pointing at the OLD executable path (must be rewritten).
OLD_EXE="/Users/x/Applications/${LEGACY_APP_NAME}/Contents/MacOS/DuePicker"
AGENT="${AGENTS_DIR}/${LOGIN_LABEL}.plist"
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

DUE_PICKER_LEGACY_DIRS="${SYS_APPS}:${HOME_APPS}" \
DUE_PICKER_BACKUP_ROOT="$BACKUP_ROOT" \
DUE_PICKER_LAUNCHAGENTS_DIR="$AGENTS_DIR" \
  bash "$INSTALLER" --migrate-only "$NEW_BUNDLE" >/dev/null

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

# 4) Login agent rewritten to the new executable; the rest preserved; mode 0600.
NEW_ARG0="$(plutil -extract ProgramArguments.0 raw -o - "$AGENT")"
[ "$NEW_ARG0" = "$NEW_EXE" ] || fail "login agent arg0 is $NEW_ARG0, expected $NEW_EXE"
[ "$(plutil -extract ProgramArguments.1 raw -o - "$AGENT")" = "--background" ] || fail "--background not preserved"
[ "$(plutil -extract Label raw -o - "$AGENT")" = "$LOGIN_LABEL" ] || fail "Label not preserved"
[ "$(plutil -extract RunAtLoad raw -o - "$AGENT")" = "true" ] || fail "RunAtLoad not preserved"
[ "$(plutil -extract ProcessType raw -o - "$AGENT")" = "Interactive" ] || fail "ProcessType not preserved"
MODE_AGENT="$(stat -f '%Lp' "$AGENT")"
[ "$MODE_AGENT" = "600" ] || fail "login agent mode is $MODE_AGENT, expected 600"
pass "login agent rewritten, other keys preserved, mode 0600"

# 5) An absent login agent is never created.
rm -f "$AGENT"
make_bundle "$SYS_APPS" "$LEGACY_APP_NAME" "$BUNDLE_ID" # re-add so there is work
DUE_PICKER_LEGACY_DIRS="${SYS_APPS}:${HOME_APPS}" \
DUE_PICKER_BACKUP_ROOT="$BACKUP_ROOT" \
DUE_PICKER_LAUNCHAGENTS_DIR="$AGENTS_DIR" \
  bash "$INSTALLER" --migrate-only "$NEW_BUNDLE" >/dev/null
[ ! -e "$AGENT" ] || fail "absent login agent was created"
pass "absent login agent not created"

# 6) The real system paths were never touched (we only used temp dirs).
printf 'Installer migration self-test passed.\n'
