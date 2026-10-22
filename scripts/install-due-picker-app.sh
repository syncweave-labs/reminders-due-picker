#!/usr/bin/env bash
# Installs "Reminders Due Picker.app" from the reviewed main commit into the
# system Applications folder (/Applications), then migrates any legacy
# "미리알림 날짜.app" bundle and the login agent that pointed at it.
set -euo pipefail

APP_NAME="Reminders Due Picker.app"
LEGACY_APP_NAME="미리알림 날짜.app"
EXECUTABLE="DuePicker"
LOGIN_LABEL="com.icloud-reminders-google-sync.due-picker.login"
# Kept from the app's first release, when it lived in reminders-task-bridge:
# macOS ties the Reminders permission to this identifier, and the replace step
# below refuses a bundle with any other one.
BUNDLE_ID="com.icloud-reminders-google-sync.due-picker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
# Default install target is /Applications (the owner's Dock tile lives there,
# next to Answer Display). Override with --applications-dir or DUE_PICKER_INSTALL_DIR.
INSTALL_DIR="${DUE_PICKER_INSTALL_DIR:-/Applications}"
OPEN_AFTER=0
REVEAL_AFTER=0
MIGRATE_ONLY=0
MIGRATE_BUNDLE=""
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Injectable paths so the migration can be tested against temp dirs without
# ever touching the real /Applications, ~/Applications, LaunchAgents or Dock.
# DUE_PICKER_LEGACY_DIRS is a colon-separated list of directories to scan for a
# legacy bundle; defaults to /Applications and ~/Applications.
LEGACY_DIRS="${DUE_PICKER_LEGACY_DIRS:-/Applications:${HOME}/Applications}"
BACKUP_ROOT="${DUE_PICKER_BACKUP_ROOT:-${HOME}/.local/state/apps/backups}"
LAUNCHAGENTS_DIR="${DUE_PICKER_LAUNCHAGENTS_DIR:-${HOME}/Library/LaunchAgents}"

usage() {
  cat <<'USAGE'
Usage:
  DEPLOY_EXPECTED_COMMIT=<full-reviewed-main-sha> \
    bash scripts/install-due-picker-app.sh [--applications-dir DIR] [--open] [--reveal]

Builds the app from the verified main checkout and replaces
/Applications/Reminders Due Picker.app in one step. The release-source gate
(scripts/check-release-source.sh) runs first, so a task branch, a dirty tree or
an unpushed commit is never installed. After the new bundle is verified it
migrates a legacy "미리알림 날짜.app" (moved to a backup, never deleted) and
rewrites the login agent to the new executable.

Options:
  --applications-dir DIR  Install somewhere other than /Applications.
  --open                  Open the app after installing.
  --reveal                Show the installed app in Finder.
  -h, --help              Show this help.

The app saves every change as it is made, so a running copy is closed before
it is replaced.

Testing only:
  --migrate-only BUNDLE   Skip the gate/build/install and run just the legacy
                          and login-agent migration, treating BUNDLE as the
                          freshly installed app. Honors DUE_PICKER_LEGACY_DIRS,
                          DUE_PICKER_BACKUP_ROOT and DUE_PICKER_LAUNCHAGENTS_DIR.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

bundle_id_of() {
  plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

register_launch_services() {
  # Registering is a no-op on systems without lsregister (e.g. a sandbox test).
  [ -x "$LSREGISTER" ] || return 0
  "$LSREGISTER" "$@" >/dev/null 2>&1 || true
}

# Move a legacy bundle whose id matches into a timestamped backup, unregister
# it, and leave a bundle with any other id alone with a warning.
migrate_legacy_bundles() {
  local new_bundle="$1"
  local stamp dir legacy legacy_id backup_dir
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local IFS=:
  for dir in $LEGACY_DIRS; do
    [ -n "$dir" ] || continue
    legacy="${dir}/${LEGACY_APP_NAME}"
    [ -d "$legacy" ] || continue
    # Never move the bundle we just installed, even if someone points a legacy
    # dir at the install dir under the legacy name.
    if [ "$(cd "$legacy" 2>/dev/null && pwd -P)" = "$(cd "$new_bundle" 2>/dev/null && pwd -P)" ]; then
      continue
    fi
    legacy_id="$(bundle_id_of "$legacy")"
    if [ "$legacy_id" != "$BUNDLE_ID" ]; then
      printf 'WARN: leaving %s alone (bundle id: %s, not %s).\n' "$legacy" "${legacy_id:-unknown}" "$BUNDLE_ID" >&2
      continue
    fi
    mkdir -p "$BACKUP_ROOT"
    chmod 0700 "$BACKUP_ROOT" 2>/dev/null || true
    backup_dir="${BACKUP_ROOT}/${stamp}"
    mkdir -p "$backup_dir"
    chmod 0700 "$backup_dir" 2>/dev/null || true
    register_launch_services -u "$legacy"
    printf '==> Backing up legacy %s -> %s\n' "$legacy" "${backup_dir}/${LEGACY_APP_NAME}"
    mv "$legacy" "${backup_dir}/${LEGACY_APP_NAME}"
  done
}

# Rewrite the login agent's ProgramArguments to exactly
# [new_executable, --background], keeping Label/RunAtLoad/ProcessType. Never
# create it if absent. Atomic write, mode 0600. Idempotent on re-run.
#
# The whole ProgramArguments array is replaced in one shot, not index by index:
# on this macOS `plutil -replace ProgramArguments.0 ...` on a 2-element array
# inserts rather than replaces, which turned [old, --background] into
# [new, --background, old, --background]. `-replace ProgramArguments -json`
# swaps the entire value atomically and is immune to that.
migrate_login_agent() {
  local new_executable="$1"
  local plist="${LAUNCHAGENTS_DIR}/${LOGIN_LABEL}.plist"
  [ -f "$plist" ] || return 0
  # Already exactly [new_executable, --background]? Then there is nothing to do.
  local arg0 arg1 count
  arg0="$(plutil -extract ProgramArguments.0 raw -o - "$plist" 2>/dev/null || true)"
  arg1="$(plutil -extract ProgramArguments.1 raw -o - "$plist" 2>/dev/null || true)"
  count="$(plutil -extract ProgramArguments raw -o - "$plist" 2>/dev/null | head -n1 || true)"
  if [ "$arg0" = "$new_executable" ] && [ "$arg1" = "--background" ] && [ "$count" = "2" ]; then
    return 0
  fi
  # Build the replacement array as JSON. The executable path can contain spaces
  # but not control characters; escape backslashes and double quotes for JSON.
  local esc
  esc="$new_executable"
  esc="${esc//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  local tmp
  tmp="$(mktemp "${LAUNCHAGENTS_DIR}/.login-agent.XXXXXX")"
  cp "$plist" "$tmp"
  plutil -replace ProgramArguments -json "[\"${esc}\", \"--background\"]" "$tmp" \
    || { rm -f "$tmp"; die "Could not rewrite the login agent."; }
  chmod 0600 "$tmp"
  mv "$tmp" "$plist"
  printf '==> Rewrote login agent ProgramArguments -> [%s, --background]\n' "$new_executable"
}

run_migration() {
  local new_bundle="$1"
  local new_executable="${new_bundle}/Contents/MacOS/${EXECUTABLE}"
  migrate_legacy_bundles "$new_bundle"
  migrate_login_agent "$new_executable"
  register_launch_services -f "$new_bundle"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --applications-dir)
      shift
      [ "$#" -gt 0 ] || die "--applications-dir requires a value."
      INSTALL_DIR="$1"
      ;;
    --open)
      OPEN_AFTER=1
      ;;
    --reveal)
      REVEAL_AFTER=1
      ;;
    --migrate-only)
      shift
      [ "$#" -gt 0 ] || die "--migrate-only requires a bundle path."
      MIGRATE_ONLY=1
      MIGRATE_BUNDLE="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift
done

# Test entry point: run only the migration against the injected directories.
if [ "$MIGRATE_ONLY" -eq 1 ]; then
  [ -d "$MIGRATE_BUNDLE" ] || die "--migrate-only bundle not found: $MIGRATE_BUNDLE"
  run_migration "$(cd "$MIGRATE_BUNDLE" && pwd -P)"
  printf 'Migration complete.\n'
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || die "The app installs only on macOS."
bash "${SCRIPT_DIR}/check-release-source.sh" --source-dir "$SOURCE_DIR"
RELEASE_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD | tr 'A-F' 'a-f')"

case "$INSTALL_DIR" in
  /*) ;;
  *) die "The applications directory must be an absolute path." ;;
esac
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
case "${INSTALL_DIR}/" in
  "${SOURCE_DIR}/"*) die "The applications directory must not be inside the source checkout." ;;
esac
TARGET="${INSTALL_DIR}/${APP_NAME}"
if [ -L "$TARGET" ]; then
  die "Install path is a symlink; remove it first: $TARGET"
fi
if [ -e "$TARGET" ]; then
  [ -d "$TARGET" ] || die "Install path exists and is not an app bundle: $TARGET"
  EXISTING_ID="$(bundle_id_of "$TARGET")"
  [ "$EXISTING_ID" = "$BUNDLE_ID" ] || die "Refusing to replace a different app at $TARGET (bundle id: ${EXISTING_ID:-unknown})."
fi

# Stage next to the target so the final step is a same-volume rename.
STAGING="$(mktemp -d "${INSTALL_DIR}/.due-picker-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
bash "${SCRIPT_DIR}/build-due-picker-app.sh" --output "$STAGING" --release-commit "$RELEASE_COMMIT"
BUILT="${STAGING}/${APP_NAME}"
codesign --verify --strict "$BUILT"
BUILT_COMMIT="$(plutil -extract DuePickerSourceCommit raw -o - "${BUILT}/Contents/Info.plist")"
[ "$BUILT_COMMIT" = "$RELEASE_COMMIT" ] || die "Built bundle records ${BUILT_COMMIT}, expected ${RELEASE_COMMIT}."

# Migration pauses the old scheduler but keeps its files until the installed
# app completes a new consistency-verified sync. Never run this from a task branch.
python3 "${SCRIPT_DIR}/migrate-google-sync.py" prepare

if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
  printf '==> Closing the running Reminders Due Picker before replacing it\n'
  pkill -TERM -x "$EXECUTABLE" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -x "$EXECUTABLE" >/dev/null 2>&1; then
    die "Reminders Due Picker is still running. Quit it and run the installer again."
  fi
fi

printf '==> Installing %s\n' "$TARGET"
if [ -d "$TARGET" ]; then
  mv "$TARGET" "${STAGING}/previous.app"
fi
if ! mv "$BUILT" "$TARGET"; then
  if [ -d "${STAGING}/previous.app" ]; then
    mv "${STAGING}/previous.app" "$TARGET"
  fi
  die "Could not move the new app into place; the previous version was kept."
fi
codesign --verify --strict "$TARGET"

# Only after the new bundle is in place and verified: migrate the legacy bundle
# (moved to a backup, never deleted), rewrite the login agent, and register the
# new bundle with LaunchServices.
run_migration "$TARGET"

printf 'Installed: %s\n' "$TARGET"
printf 'Source commit: %s\n' "$RELEASE_COMMIT"
printf 'The first launch asks for Reminders access; allow it once.\n'
if [ "$REVEAL_AFTER" -eq 1 ]; then
  open -R "$TARGET"
fi
if [ "$OPEN_AFTER" -eq 1 ]; then
  open "$TARGET"
fi
