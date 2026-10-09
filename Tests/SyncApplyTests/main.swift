import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let operation: [String: Any] = ["operation_id": "create-1", "create": true, "title": "fixture"]
let created: [String: Any] = ["status": "created", "id": "reminder-1", "stable_id": "reminder-1"]
var saved: [String: [String: Any]] = [:]
var commits = 0
struct LostResponse: Error {}

// The real journal, a fake EventKit commit, and a fresh journal after restart.
do {
    let journal = try SyncApplyJournal(directory: root)
    do {
        _ = try journal.create(operation: operation, stage: { "reminder-1" }, commit: {
            commits += 1
            saved["reminder-1"] = created
            throw LostResponse()
        }, readback: { saved[$0] })
        fatalError("failure injection was not reached")
    } catch is LostResponse {}
}
do {
    let journal = try SyncApplyJournal(directory: root)
    let recovered = try journal.create(operation: operation, stage: { fatalError("must not stage twice") },
        commit: { fatalError("must not commit twice") }, readback: { saved[$0] })
    assert(recovered["status"] as? String == "created")
    assert(recovered["operation_id"] as? String == "create-1")
    assert(commits == 1)
    saved = [:] // A later user deletion must not recreate the operation.
    let replay = try journal.create(operation: operation, stage: { fatalError() }, commit: { fatalError() }, readback: { _ in nil })
    assert(replay["id"] as? String == "reminder-1")
    var changed = operation; changed["title"] = "changed"
    let conflict = try journal.create(operation: changed, stage: { fatalError() }, commit: { fatalError() }, readback: { _ in nil })
    assert(conflict["status"] as? String == "operation_conflict")
}
// A response loss without an observable reminder is uncertain, not retryable.
let second: [String: Any] = ["operation_id": "create-2", "create": true]
do {
    let journal = try SyncApplyJournal(directory: root)
    do {
        _ = try journal.create(operation: second, stage: { "reminder-2" }, commit: { throw LostResponse() }, readback: { _ in nil })
        fatalError()
    } catch is LostResponse {}
}
do {
    let journal = try SyncApplyJournal(directory: root)
    let result = try journal.create(operation: second, stage: { fatalError() }, commit: { fatalError() }, readback: { _ in nil })
    assert(result["status"] as? String == "uncertain")
}
let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("creates.json").path)[.posixPermissions] as! NSNumber
assert(mode.intValue & 0o777 == 0o600)
print("Sync apply creation recovery tests passed (no EventKit writes).")
