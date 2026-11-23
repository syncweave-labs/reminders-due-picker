The MIT sync engine and regression suite were imported from
`syncweave-labs/reminders-task-bridge`, commit
`3501800b672ef58c823eb0711c22412c2db98dce`.

`icloud_reminders_google_sync.py` is that repository's engine byte for byte, as
of commit `e6368aa29cb49b672b992f5074c531426ab039d2`. Change the engine there
first, then copy the file here and update both lines; `scripts/test-due-picker.sh`
fails when the file and the hash below differ.

Engine sha256: `e1235a36264958475504aac2b8e7547a44407093ac5027798b189a4d69cc8746`

The app owns scheduling, configuration, credentials and EventKit helper modes.
The engine keeps its existing state format, conflict and mutation approval rules.
It is bundled inside the signed app, never launched from the development checkout.

Standalone installer and command-launcher assertions in the imported suite were
retired with those entrypoints. App migration, account reconnect, private-log
and signed-EventKit IPC checks replace them; synchronization regressions remain.
