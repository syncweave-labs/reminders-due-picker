#!/usr/bin/env bash
# Self-test for scripts/check-release-source.sh against a throwaway repository
# whose origin is redirected to a local bare remote. Nothing leaves the machine.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GATE="${SCRIPT_DIR}/check-release-source.sh"
EXPECTED_URL="https://github.com/syncweave-labs/reminders-due-picker.git"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/due-picker-release-gate.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

REMOTE_DIR="${TMP_ROOT}/remote.git"
SOURCE_DIR="${TMP_ROOT}/source"
OUTPUT_PATH="${TMP_ROOT}/gate-output.txt"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >"$OUTPUT_PATH" 2>&1; then
    fail "$label unexpectedly passed"
  fi
  printf 'PASS (blocked): %s\n' "$label"
}

git init --bare "$REMOTE_DIR" >/dev/null
git init "$SOURCE_DIR" >/dev/null
git -C "$SOURCE_DIR" config user.name "Release Gate Test"
git -C "$SOURCE_DIR" config user.email "release-gate@example.invalid"
git -C "$SOURCE_DIR" config core.hooksPath /dev/null
git -C "$SOURCE_DIR" branch -M main
printf 'source\n' >"${SOURCE_DIR}/tracked.txt"
git -C "$SOURCE_DIR" add tracked.txt
git -C "$SOURCE_DIR" commit -m "Initial source" >/dev/null
git -C "$SOURCE_DIR" remote add origin "$EXPECTED_URL"
git -C "$SOURCE_DIR" config "url.file://${REMOTE_DIR}.insteadOf" "$EXPECTED_URL"
git -C "$SOURCE_DIR" push -u origin main >/dev/null 2>&1

HEAD_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
DEPLOY_EXPECTED_COMMIT="$HEAD_COMMIT" "$GATE" --source-dir "$SOURCE_DIR" >/dev/null
printf 'PASS: clean reviewed main\n'

expect_failure "missing expected commit" \
  env -u DEPLOY_EXPECTED_COMMIT "$GATE" --source-dir "$SOURCE_DIR"
expect_failure "short expected commit" \
  env DEPLOY_EXPECTED_COMMIT="${HEAD_COMMIT:0:12}" "$GATE" --source-dir "$SOURCE_DIR"
expect_failure "invalid override flag" \
  env DEPLOY_EXPECTED_COMMIT="$HEAD_COMMIT" DEPLOY_GIT_ALLOW_DIRTY=yes "$GATE" --source-dir "$SOURCE_DIR"

printf 'dirty\n' >>"${SOURCE_DIR}/tracked.txt"
expect_failure "dirty worktree" \
  env DEPLOY_EXPECTED_COMMIT="$HEAD_COMMIT" "$GATE" --source-dir "$SOURCE_DIR"
expect_failure "override without reason" \
  env DEPLOY_EXPECTED_COMMIT="$HEAD_COMMIT" DEPLOY_GIT_ALLOW_DIRTY=1 "$GATE" --source-dir "$SOURCE_DIR"
DEPLOY_EXPECTED_COMMIT="$HEAD_COMMIT" \
  DEPLOY_GIT_ALLOW_DIRTY=1 \
  DEPLOY_GIT_OVERRIDE_REASON="release gate self-test" \
  "$GATE" --source-dir "$SOURCE_DIR" >/dev/null 2>&1
printf 'PASS: audited dirty override\n'
printf 'source\n' >"${SOURCE_DIR}/tracked.txt"

printf 'untracked\n' >"${SOURCE_DIR}/untracked.txt"
expect_failure "untracked file" \
  env DEPLOY_EXPECTED_COMMIT="$HEAD_COMMIT" "$GATE" --source-dir "$SOURCE_DIR"
rm -f "${SOURCE_DIR}/untracked.txt"

git -C "$SOURCE_DIR" switch -c codex/feature >/dev/null 2>&1
expect_failure "non-main branch" \
  env DEPLOY_EXPECTED_COMMIT="$HEAD_COMMIT" "$GATE" --source-dir "$SOURCE_DIR"
DEPLOY_EXPECTED_COMMIT="$HEAD_COMMIT" \
  DEPLOY_GIT_ALLOW_NON_MAIN=1 \
  DEPLOY_GIT_OVERRIDE_REASON="release gate self-test" \
  "$GATE" --source-dir "$SOURCE_DIR" >/dev/null 2>&1
printf 'PASS: audited non-main override\n'
git -C "$SOURCE_DIR" switch main >/dev/null 2>&1

printf 'second\n' >>"${SOURCE_DIR}/tracked.txt"
git -C "$SOURCE_DIR" add tracked.txt
git -C "$SOURCE_DIR" commit -m "Unpushed source" >/dev/null
UNPUSHED_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
expect_failure "unpushed commit" \
  env DEPLOY_EXPECTED_COMMIT="$UNPUSHED_COMMIT" "$GATE" --source-dir "$SOURCE_DIR"
DEPLOY_EXPECTED_COMMIT="$UNPUSHED_COMMIT" \
  DEPLOY_GIT_ALLOW_UNPUSHED=1 \
  DEPLOY_GIT_OVERRIDE_REASON="release gate self-test" \
  "$GATE" --source-dir "$SOURCE_DIR" >/dev/null 2>&1
printf 'PASS: audited unpushed override\n'
git -C "$SOURCE_DIR" push origin main >/dev/null 2>&1
DEPLOY_EXPECTED_COMMIT="$UNPUSHED_COMMIT" "$GATE" --source-dir "$SOURCE_DIR" >/dev/null
printf 'PASS: pushed main\n'

expect_failure "expected commit mismatch" \
  env DEPLOY_EXPECTED_COMMIT="0000000000000000000000000000000000000000" "$GATE" --source-dir "$SOURCE_DIR"

mkdir -p "${SOURCE_DIR}/sub"
expect_failure "source directory below the repository root" \
  env DEPLOY_EXPECTED_COMMIT="$UNPUSHED_COMMIT" "$GATE" --source-dir "${SOURCE_DIR}/sub"

git -C "$SOURCE_DIR" remote set-url origin "https://github.com/syncweave-labs/reminders-task-bridge.git"
expect_failure "sibling repository origin" \
  env DEPLOY_EXPECTED_COMMIT="$UNPUSHED_COMMIT" "$GATE" --source-dir "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote set-url origin "https://github.com/not-the-owner/not-this-repo.git"
expect_failure "unexpected origin, even with every override" \
  env DEPLOY_EXPECTED_COMMIT="$UNPUSHED_COMMIT" DEPLOY_GIT_ALLOW_DIRTY=1 DEPLOY_GIT_ALLOW_NON_MAIN=1 \
    DEPLOY_GIT_ALLOW_UNPUSHED=1 DEPLOY_GIT_OVERRIDE_REASON="release gate self-test" \
    "$GATE" --source-dir "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote set-url origin "$EXPECTED_URL"

printf 'Release source gate self-test passed.\n'
