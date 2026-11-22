The MIT sync engine and regression suite were imported from
`syncweave-labs/reminders-task-bridge`, commit
`3501800b672ef58c823eb0711c22412c2db98dce`.

`icloud_reminders_google_sync.py` is that repository's engine byte for byte, as
of commit `acc6e5623aadd2f27d87b2e8322bf2dd9a3d5bf0`. Change the engine there
first, then copy the file here and update both lines; `scripts/test-due-picker.sh`
fails when the file and the hash below differ.

Engine sha256: `5e9995a9fb7504679db01e747391aeaa048008187b7b6a3c62b2f95fef264ab3`

The app owns scheduling, configuration, credentials and EventKit helper modes.
The engine keeps its existing state format, conflict and mutation approval rules.
It is bundled inside the signed app, never launched from the development checkout.

Standalone installer and command-launcher assertions in the imported suite were
retired with those entrypoints. App migration, account reconnect, private-log
and signed-EventKit IPC checks replace them; synchronization regressions remain.
