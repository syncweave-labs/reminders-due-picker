# Agent Instructions

`reminders-due-picker` is the source of `Reminders Due Picker.app` (Korean UI,
English name for Spotlight/Alfred), a Mac-local SwiftUI + EventKit app for
changing Apple Reminders due dates and managing reminders. It is an independent
source repository. EventKit access, code signing, and the installed app stay on
the user's Mac and are never proved by source CI alone.

## Product Contract

- A date change writes only a reminder's due date, the start date that mirrored
  it, and the clock alarms anchored to the due time. Titles, notes, lists,
  priority, and recurrence are never written by a date action.
- A recurring reminder never loses its due date, read-only lists are skipped,
  only selected reminders the list is currently showing change, and a reminder
  that changed after the list was loaded is left alone.
- Every action saves as one EventKit batch; a refused commit changes nothing.
  Undo restores the exact previous state.
- Management actions apply to the currently visible selection, as one batch each,
  with the same read-only and staleness guards as the date apply:
  - Complete / mark incomplete writes only the completion flag and date (with
    undo). Recurring reminders are refused, never silently advanced, because
    completing a recurrence through EventKit cannot be proven safe on the
    unsaved objects the tests touch. A 완료됨 smart list shows reminders
    completed in the last 30 days so un-completing is reachable.
  - Delete removes the reminders (batch, behind a confirmation that states the
    count). It has no undo and reaches the Google Tasks / Notion mirrors on
    their next sync under the existing sync safety gates.
  - Edit writes only a single reminder's title (non-empty, trimmed, capped) and
    notes (capped), with undo. No other field changes.
  - Move changes only the list of the selected reminders, to another writable
    list, with undo.
  - Priority writes only the priority (none/low/medium/high), with undo; a value
    Reminders set inside the same displayed bucket is left as-is.
- Date editing and management are local. Optional Google Tasks sync sends
  reminder data to the connected Google account. The app owns credentials, state
  and private logs in `~/Library/Application Support/RemindersDuePicker/GoogleSync`.
- The sync popover also shows a read-only Notion mirror status (lastSuccessAt,
  pendingCreates, counts.total) from the Planner bridge's
  `~/.config/planner-studio/notion-mirror-state.json`. The app only reads those
  three fields, never writes that file, and never reads env files or tokens; a
  missing or unreadable file is a neutral "cannot determine" state.
- Google sync preserves the imported engine's conflict, account-binding and
  destructive-plan approval rules. The engine ships inside the signed bundle;
  EventKit exports and writes run through helper modes of the same app binary.
- Closing the window keeps automatic sync in the menu bar. Quitting stops the
  worker. Login starts the installed app, never a development checkout. On a
  normal launch the app self-heals the login agent when it points at a stale
  executable (app moved or renamed); it never creates the agent when absent.

## Source And Runtime Ownership

- Source repository: the root of this Git checkout.
- Installed app: `/Applications/Reminders Due Picker.app`, bundle identifier
  `com.icloud-reminders-google-sync.due-picker`, executable
  `Contents/MacOS/DuePicker`. The identifier and executable name are kept from
  the app's first release in `syncweave-labs/reminders-task-bridge`: macOS ties
  the Reminders permission to the identifier, the Planner bridge runs the
  executable by name, and the installer refuses to replace a bundle with another
  identifier. Do not change them. The data directory
  `~/Library/Application Support/RemindersDuePicker` is unchanged. The bundle
  carries no localized `InfoPlist.strings`, so Finder/Spotlight/Alfred show the
  English `CFBundleName`/`CFBundleDisplayName`.
- The installer's default target is `/Applications`; `--applications-dir`
  overrides it. After installing and verifying the new bundle it moves a legacy
  `미리알림 날짜.app` whose id matches into a timestamped, mode-0700 backup under
  `~/.local/state/apps/backups/` (never deletes it), leaves a bundle with any
  other id alone, rewrites the login agent to the new executable (never creating
  it when absent), and registers the new bundle with LaunchServices.
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
- `Sources/ReminderStore.swift`: EventKit reads, guarded batch writes and undo
  for dates and for the management actions (complete, delete, edit, move,
  priority), plus the completed-list fetch.
- `Sources/AppModel.swift`: selection, filters, apply, management actions, the
  완료됨 smart list, quick add.
- `Sources/SyncSupport.swift`: Foundation-only helpers the tests also compile —
  the login-agent reader/writer/self-heal and the read-only Notion status parser.
- `Sources/Views.swift`, `Sources/App.swift`: SwiftUI window, inspector,
  context menu, menus and shortcuts (date actions and management).
- `Tests/CoreTests/`, `Tests/AppTests/`: plain `swiftc` test runners (no XCTest).
- `Tools/`: icon generator, demo backend, offscreen snapshot renderer. Not part
  of the app bundle.
- `scripts/`: build, test, release gate, installer, and the installer-migration
  self-test (`test-install-migration.sh`, run by `test-due-picker.sh` on macOS
  against temp dirs only).

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
