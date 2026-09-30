#!/usr/bin/env bash
# Release-source gate for 미리알림 날짜. scripts/install-due-picker-app.sh runs
# it before it builds or replaces anything, so only a clean, pushed main commit
# is ever installed.
set -euo pipefail

EXPECTED_REPOSITORY="syncweave-labs/reminders-due-picker"
EXPECTED_BRANCH="main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

usage() {
  cat <<'USAGE'
Usage:
  DEPLOY_EXPECTED_COMMIT=<full-sha> bash scripts/check-release-source.sh [--source-dir DIR]

Options:
  --source-dir DIR  Source directory to verify. Defaults to the repository root.
  -h, --help        Show this help.

A release requires a clean main checkout whose HEAD matches both origin/main
and the live origin main ref. DEPLOY_EXPECTED_COMMIT is mandatory and must be
the full local HEAD.

Emergency overrides:
  DEPLOY_GIT_ALLOW_DIRTY=1
  DEPLOY_GIT_ALLOW_NON_MAIN=1
  DEPLOY_GIT_ALLOW_UNPUSHED=1

Every override requires a non-empty DEPLOY_GIT_OVERRIDE_REASON. The expected
GitHub origin cannot be overridden.
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn_override() {
  printf 'AUDIT OVERRIDE: %s; reason=%s\n' "$1" "$DEPLOY_GIT_OVERRIDE_REASON" >&2
}

validate_flag() {
  local name="$1"
  local value="$2"
  case "$value" in
    0|1) ;;
    *) die "${name} must be 0 or 1." ;;
  esac
}

origin_repository() {
  local url="$1"
  local repository=""

  case "$url" in
    https://github.com/*)
      repository="${url#https://github.com/}"
      ;;
    git@github.com:*)
      repository="${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      repository="${url#ssh://git@github.com/}"
      ;;
    *)
      return 1
      ;;
  esac

  repository="${repository%/}"
  repository="${repository%.git}"
  printf '%s\n' "$repository"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-dir)
      shift
      [ "$#" -gt 0 ] || die "--source-dir requires a value."
      [ -d "$1" ] || die "Source directory does not exist: $1"
      SOURCE_DIR="$(cd "$1" && pwd -P)"
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

ALLOW_DIRTY="${DEPLOY_GIT_ALLOW_DIRTY:-0}"
ALLOW_NON_MAIN="${DEPLOY_GIT_ALLOW_NON_MAIN:-0}"
ALLOW_UNPUSHED="${DEPLOY_GIT_ALLOW_UNPUSHED:-0}"
DEPLOY_GIT_OVERRIDE_REASON="${DEPLOY_GIT_OVERRIDE_REASON:-}"
EXPECTED_COMMIT="${DEPLOY_EXPECTED_COMMIT:-}"

validate_flag DEPLOY_GIT_ALLOW_DIRTY "$ALLOW_DIRTY"
validate_flag DEPLOY_GIT_ALLOW_NON_MAIN "$ALLOW_NON_MAIN"
validate_flag DEPLOY_GIT_ALLOW_UNPUSHED "$ALLOW_UNPUSHED"

if [ "$ALLOW_DIRTY" -eq 1 ] || [ "$ALLOW_NON_MAIN" -eq 1 ] || [ "$ALLOW_UNPUSHED" -eq 1 ]; then
  [ -n "$DEPLOY_GIT_OVERRIDE_REASON" ] || die "DEPLOY_GIT_OVERRIDE_REASON is required when an override is enabled."
fi

[ -n "$EXPECTED_COMMIT" ] || die "DEPLOY_EXPECTED_COMMIT must contain the full reviewed commit SHA."
case "$EXPECTED_COMMIT" in
  *[!0-9a-fA-F]*) die "DEPLOY_EXPECTED_COMMIT must be a hexadecimal full commit SHA." ;;
esac
[ "${#EXPECTED_COMMIT}" -eq 40 ] || die "DEPLOY_EXPECTED_COMMIT must be the full 40-character commit SHA."
EXPECTED_COMMIT="$(printf '%s' "$EXPECTED_COMMIT" | tr 'A-F' 'a-f')"

git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Source is not a Git worktree: $SOURCE_DIR"
GIT_ROOT="$(git -C "$SOURCE_DIR" rev-parse --show-toplevel)"
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"
[ "$GIT_ROOT" = "$SOURCE_DIR" ] || die "Source directory must be the repository root: $GIT_ROOT"

ORIGIN_URL="$(git -C "$SOURCE_DIR" config --get remote.origin.url 2>/dev/null || true)"
[ -n "$ORIGIN_URL" ] || die "origin is not configured."
ORIGIN_REPOSITORY="$(origin_repository "$ORIGIN_URL" || true)"
[ "$ORIGIN_REPOSITORY" = "$EXPECTED_REPOSITORY" ] || die "origin must be ${EXPECTED_REPOSITORY}, got: ${ORIGIN_URL}"

HEAD_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD | tr 'A-F' 'a-f')"
[ "$HEAD_COMMIT" = "$EXPECTED_COMMIT" ] || die "HEAD ${HEAD_COMMIT} does not match DEPLOY_EXPECTED_COMMIT ${EXPECTED_COMMIT}."

CURRENT_BRANCH="$(git -C "$SOURCE_DIR" branch --show-current)"
if [ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]; then
  [ "$ALLOW_NON_MAIN" -eq 1 ] || die "Release source must be on ${EXPECTED_BRANCH}, got: ${CURRENT_BRANCH:-detached HEAD}"
  warn_override "non-main branch ${CURRENT_BRANCH:-detached HEAD}"
fi

WORKTREE_STATUS="$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all)"
if [ -n "$WORKTREE_STATUS" ]; then
  [ "$ALLOW_DIRTY" -eq 1 ] || die "Release source has tracked or untracked changes."
  warn_override "dirty worktree"
fi

ORIGIN_MAIN="$(git -C "$SOURCE_DIR" rev-parse --verify refs/remotes/origin/main 2>/dev/null || true)"
REMOTE_MAIN="$(git -C "$SOURCE_DIR" ls-remote --exit-code origin refs/heads/main 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
ORIGIN_MAIN="$(printf '%s' "$ORIGIN_MAIN" | tr 'A-F' 'a-f')"
REMOTE_MAIN="$(printf '%s' "$REMOTE_MAIN" | tr 'A-F' 'a-f')"

if [ "$ORIGIN_MAIN" != "$HEAD_COMMIT" ] || [ "$REMOTE_MAIN" != "$HEAD_COMMIT" ]; then
  [ "$ALLOW_UNPUSHED" -eq 1 ] || die "HEAD must match both local origin/main and live origin main."
  warn_override "HEAD differs from origin/main or live origin main"
fi

printf 'Release source verified: repository=%s branch=%s commit=%s mode=git\n' \
  "$EXPECTED_REPOSITORY" "$CURRENT_BRANCH" "$HEAD_COMMIT"
