## Scope and result

- Scope:
- Result:

## Verification

- [ ] `bash -n scripts/*.sh`
- [ ] `bash scripts/test-release-source-gate.sh`
- [ ] `bash scripts/test-due-picker.sh` (on macOS: date rules plus EventKit and app-model tests)
- [ ] `bash scripts/build-due-picker-app.sh`
- [ ] For view changes: `bash scripts/build-due-picker-app.sh --snapshots <dir>` checked in light and dark mode
- [ ] GitHub Actions CI is green.

## Reminders data safety

- [ ] No reminder titles, account identifiers, exported data, local absolute paths, or signing identities are included.
- [ ] Nothing was tested against real reminders; write-path tests use unsaved in-memory objects or the demo backend.
- [ ] Any change to what a date change writes (due, start, alarms) is described below.

Install impact:

Rollback:
