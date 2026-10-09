import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// A creation receipt lives beside the installed app's private runtime state.
// The fence is persisted BEFORE EventKit commits, so a lost helper response
// never permits another creation. Recovery only reads the recorded identifier.
final class SyncApplyJournal {
    private struct Entry: Codable {
        var payload: Data
        var identifier: String
        var result: Data?
    }
    private let file: URL
    private let lock: Int32
    private var entries: [String: Entry]

    init(directory: URL) throws {
        let fm = FileManager.default
        for url in [directory, directory.appendingPathComponent("creates.json"), directory.appendingPathComponent("creates.lock")] {
            if (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw NSError(domain: "SyncApply", code: 1, userInfo: [NSLocalizedDescriptionKey: "Creation journal contains a symbolic link."])
            }
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        file = directory.appendingPathComponent("creates.json")
        lock = open(directory.appendingPathComponent("creates.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(lock, LOCK_EX) == 0 else {
            close(lock)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        do {
            if fm.fileExists(atPath: file.path) {
                entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
            } else {
                entries = [:]
            }
        } catch {
            flock(lock, LOCK_UN); close(lock)
            throw error
        }
    }

    deinit { flock(lock, LOCK_UN); close(lock) }

    private func persist() throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func recover(operation: [String: Any], readback: (String) -> [String: Any]?) throws -> [String: Any]? {
        let id = (operation["operation_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = try JSONSerialization.data(withJSONObject: operation, options: .sortedKeys)
        if var entry = entries[id] {
            guard entry.payload == payload else {
                return ["status": "operation_conflict", "operation_id": id]
            }
            if let data = entry.result {
                guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "SyncApply", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid creation receipt."])
                }
                return result
            }
            guard !entry.identifier.isEmpty, var result = readback(entry.identifier) else {
                // Absence does not prove that an interrupted external commit
                // failed. Leave the request pending for explicit reconciliation.
                return ["status": "uncertain", "operation_id": id, "reason": "create_commit_unconfirmed"]
            }
            result["operation_id"] = id
            entry.result = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
            entries[id] = entry
            try persist()
            return result
        }
        return nil
    }

    func create(operation: [String: Any], stage: () throws -> String,
                commit: () throws -> [String: Any], readback: (String) -> [String: Any]?) throws -> [String: Any] {
        let id = (operation["operation_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!id.isEmpty)
        if let result = try recover(operation: operation, readback: readback) { return result }
        let payload = try JSONSerialization.data(withJSONObject: operation, options: .sortedKeys)
        let identifier = try stage() // save(commit:false), not a live commit
        entries[id] = Entry(payload: payload, identifier: identifier, result: nil)
        try persist()
        var result = try commit()
        result["operation_id"] = id
        entries[id]?.result = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        try persist()
        return result
    }
}
