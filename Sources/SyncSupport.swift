// SyncSupport.swift — Foundation-only helpers shared by the app and its tests:
// the login-launch LaunchAgent reader/writer/self-heal, and the read-only
// Notion mirror status parser. No AppKit or SwiftUI, so the macOS test runner
// compiles them without pulling in the UI.

import Foundation

/// Reads, writes and self-heals the login-launch LaunchAgent plist. All paths
/// are explicit so the decision and rewrite can be tested against a temp dir
/// without touching the real ~/Library/LaunchAgents.
enum LoginAgent {
    static func path(label: String, agentsDirectory: URL) -> URL {
        agentsDirectory.appendingPathComponent("\(label).plist")
    }

    /// The canonical plist content: ProgramArguments[0] is the executable and
    /// `--background` follows; Label/RunAtLoad/ProcessType are fixed.
    static func plist(label: String, executablePath: String) -> [String: Any] {
        ["Label": label, "ProgramArguments": [executablePath, "--background"],
         "RunAtLoad": true, "ProcessType": "Interactive"]
    }

    static func write(label: String, agentsDirectory: URL, executablePath: String) throws {
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(label: label, executablePath: executablePath), format: .xml, options: 0)
        let target = path(label: label, agentsDirectory: agentsDirectory)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    static func remove(label: String, agentsDirectory: URL) throws {
        try? FileManager.default.removeItem(at: path(label: label, agentsDirectory: agentsDirectory))
    }

    /// The executable the plist currently points at, or nil if absent/unreadable.
    static func currentExecutable(label: String, agentsDirectory: URL) -> String? {
        let target = path(label: label, agentsDirectory: agentsDirectory)
        guard let data = try? Data(contentsOf: target),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any],
              let args = dict["ProgramArguments"] as? [String], let first = args.first else { return nil }
        return first
    }

    /// True when the agent exists and points at a different executable.
    static func needsSelfHeal(label: String, agentsDirectory: URL, executablePath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path(label: label, agentsDirectory: agentsDirectory).path) else {
            return false // Never create it when absent.
        }
        return currentExecutable(label: label, agentsDirectory: agentsDirectory) != executablePath
    }

    /// Rewrites the agent only when it exists and is stale; returns whether it did.
    @discardableResult
    static func selfHeal(label: String, agentsDirectory: URL, executablePath: String) throws -> Bool {
        guard needsSelfHeal(label: label, agentsDirectory: agentsDirectory, executablePath: executablePath) else {
            return false
        }
        try write(label: label, agentsDirectory: agentsDirectory, executablePath: executablePath)
        return true
    }
}

/// Read-only view of the Planner Mac bridge's Notion mirror state. The bridge
/// (`io.codex.planner-reminders-bridge`) writes this file every ~60 s from this
/// app's `--sync-export`; the app only ever reads three fields from it and
/// never writes it, never reads env files or tokens.
struct NotionMirrorStatus: Equatable {
    var lastSuccessAt: Date?
    var pendingCreates: Int
    var total: Int
    /// True when the file was missing or unreadable: a neutral state, not an error.
    var unavailable: Bool

    static let unknown = NotionMirrorStatus(lastSuccessAt: nil, pendingCreates: 0, total: 0, unavailable: true)

    /// Default location written by the Planner bridge.
    static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/planner-studio/notion-mirror-state.json")
    }

    /// Parses the three fields from a JSON object. Only `lastSuccessAt`,
    /// `pendingCreates` and `counts.total` are read; anything else is ignored.
    static func parse(_ object: Any?) -> NotionMirrorStatus {
        guard let json = object as? [String: Any] else { return .unknown }
        var date: Date?
        if let iso = json["lastSuccessAt"] as? String, !iso.isEmpty {
            date = ISO8601DateFormatter().date(from: iso)
                ?? {
                    let f = ISO8601DateFormatter()
                    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    return f.date(from: iso)
                }()
        }
        let pending = (json["pendingCreates"] as? Int) ?? Int((json["pendingCreates"] as? Double) ?? 0)
        var total = 0
        if let counts = json["counts"] as? [String: Any] {
            total = (counts["total"] as? Int) ?? Int((counts["total"] as? Double) ?? 0)
        }
        return NotionMirrorStatus(lastSuccessAt: date, pendingCreates: max(pending, 0),
                                  total: max(total, 0), unavailable: false)
    }

    /// Reads and parses the state file; a missing or unreadable file is a
    /// neutral `unavailable` state, never an error.
    static func read(from url: URL) -> NotionMirrorStatus {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else { return .unknown }
        return parse(object)
    }
}
