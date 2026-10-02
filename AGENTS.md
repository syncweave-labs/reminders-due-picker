# Agent Instructions

`reminders-due-picker` is the source of `미리알림 날짜.app`, a Mac-local SwiftUI
+ EventKit app for changing Apple Reminders due dates. It is an independent
source repository. EventKit access, code signing, and the installed app stay on
the user's Mac and are never proved by source CI alone.

## Product Contract

- A date change writes only a reminder's due date, the start date that mirrored
  it, and the clock alarms anchored to the due time. Titles, notes, lists,
  priority, and recurrence are never written.
- A recurring reminder never loses its due date, read-only lists are skipped,
  only selected reminders the list is currently showing change, and a reminder
  that changed after the list was loaded is left alone.
- Every action saves as one EventKit batch; a refused commit changes nothing.
  Undo restores due, start, and alarms exactly.
- Date editing is local. Optional Google Tasks sync sends reminder data to the
  connected Google account. The app owns credentials, state and private logs in
  `~/Library/Application Support/RemindersDuePicker/GoogleSync`.
- Google sync preserves the imported engine's conflict, account-binding and
  destructive-plan approval rules. The engine ships inside the signed bundle;
  EventKit exports and writes run through helper modes of the same app binary.
- Closing the window keeps automatic sync in the menu bar. Quitting stops the
  worker. Login starts the installed app, never a development checkout.

## Source And Runtime Ownership

- Source repository: the root of this Git checkout.
- Installed app: `~/Applications/미리알림 날짜.app`, bundle identifier
  `com.icloud-reminders-google-sync.due-picker`. The identifier is kept from the
  app's first release in `syncweave-labs/reminders-task-bridge`: macOS ties the
  Reminders permission to it, and the installer refuses to replace a bundle with
  another identifier. Do not change it.
- The installed bundle records its source in
  `Contents/Resources/release-source.txt` and in `DuePickerSourceCommit` of its
  `Info.plist`.

## Git Workflow

- Inspect status, branch, origin, and upstream before editing.
- Work on `codex/<task>` from current `origin/main`, preferably in a worktree;
  preserve unrelated changes and stage explicit paths.
- Keep `origin` equal to `syncweave-labs/reminders-due-picker`.
- Push a reviewed branch, merge it to `main` only after CI is green, and
  fast-forward the local `main` checkout before installing.
- Never install from an arbitrary branch, a dirty worktree, or an unpushed
  commit.

## Release And Installation

`scripts/install-due-picker-app.sh` builds, signs, and replaces the installed
app. Before any of that it runs:

```sh
DEPLOY_EXPECTED_COMMIT=<full-reviewed-main-sha> \
  bash scripts/check-release-source.sh
```

The gate requires a clean `main`, the expected GitHub origin, and equality
between `HEAD`, local `origin/main`, live origin main, and
`DEPLOY_EXPECTED_COMMIT`. Narrow emergency overrides require
`DEPLOY_GIT_OVERRIDE_REASON`; the expected origin is never overridable.

Install only when the user asked for the app to be installed or updated. The
installer closes a running copy before replacing it.

## Structure

- `Sources/DueCore.swift`: pure date rules, the Korean input parser, and the
  alarm and start-date plans. Foundation only; CI also builds it on Linux.
- `Sources/ReminderStore.swift`: EventKit reads, guarded batch writes, undo.
- `Sources/AppModel.swift`: selection, filters, apply, quick add.
- `Sources/Views.swift`, `Sources/App.swift`: SwiftUI window, menus, shortcuts.
- `Tests/CoreTests/`, `Tests/AppTests/`: plain `swiftc` test runners (no XCTest).
- `Tools/`: icon generator, demo backend, offscreen snapshot renderer. Not part
  of the app bundle.
- `scripts/`: build, test, release gate, and installer.

The app builds with the Command Line Tools only. SwiftUI's `@State` is a macro
whose compiler plugin ships only with Xcode, so view-local state lives in
`ObservableObject`s instead.

## Required Source Checks

Run from this repository:

```sh
bash -n scripts/*.sh
bash scripts/test-release-source-gate.sh
bash scripts/test-due-picker.sh
bash scripts/build-due-picker-app.sh
```

For a change to the views, also render
`bash scripts/build-due-picker-app.sh --snapshots <dir>` and look at the light
and dark images; the snapshots use demo data only. Never test the app's write
path against real reminders: EventKit tests edit unsaved in-memory objects, and
model tests use `Tools/DemoBackend.swift`.
