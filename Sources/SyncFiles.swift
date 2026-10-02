import Foundation

enum SyncFiles {
    static func openPrivateLog(in directory: URL, maxBytes: Int = 5_242_880) throws -> FileHandle {
        let fm = FileManager.default
        func refuseLink(_ path: URL) throws {
            if (try? fm.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw NSError(domain: "GoogleSync", code: 3, userInfo: [NSLocalizedDescriptionKey: "동기화 저장소에 심볼릭 링크가 있어 작업을 중단했습니다."])
            }
        }
        try refuseLink(directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let log = directory.appendingPathComponent("sync.log")
        let previous = directory.appendingPathComponent("sync.log.1")
        try refuseLink(log); try refuseLink(previous)
        if let size = (try? fm.attributesOfItem(atPath: log.path)[.size]) as? Int, size > maxBytes {
            if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
            try fm.moveItem(at: log, to: previous)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
        }
        if !fm.fileExists(atPath: log.path) {
            fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        return handle
    }
}
