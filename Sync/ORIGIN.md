The MIT sync engine and regression suite were imported from
`syncweave-labs/reminders-task-bridge`, commit
`3501800b672ef58c823eb0711c22412c2db98dce`.

The app owns scheduling, configuration, credentials and EventKit helper modes.
The engine keeps its existing state format, conflict and mutation approval rules.
It is bundled inside the signed app, never launched from the development checkout.

Standalone installer and command-launcher assertions in the imported suite were
retired with those entrypoints. App migration, account reconnect, private-log
and signed-EventKit IPC checks replace them; synchronization regressions remain.
