import AppKit
import Combine
import Foundation
import Darwin
import SwiftUI

/// The window and login launch both use one app-owned engine process.
@MainActor
final class GoogleSync: ObservableObject {
    static let shared = GoogleSync()
    @Published var showsSettings = false
    @Published private(set) var enabled: Bool
    @Published private(set) var busy = false
    @Published private(set) var state = "disconnected"
    @Published private(set) var message = "Google Tasks를 연결하면 미리알림과 자동으로 동기화합니다."
    @Published private(set) var account = ""
    @Published private(set) var lastSuccess: Date?
    private var worker: Process?
    private var operation: Process?
    private var timer: Timer?
    private var started = false
    private let demo: Bool
    let dataDirectory: URL
    private let label = "com.icloud-reminders-google-sync.due-picker.login"

    init(demo: Bool = false, dataDirectory: URL? = nil) {
        self.demo = demo
        self.dataDirectory = dataDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RemindersDuePicker/GoogleSync")
        enabled = demo || UserDefaults.standard.bool(forKey: "GoogleSyncEnabled")
        if demo { state = "ok"; account = "user@example.com"; lastSuccess = Date(); message = "미리알림과 Google Tasks가 동기화되었습니다." }
    }

    func start() {
        guard !started, !demo else { return }
        started = true
        readStatus()
        // Migration restores the enabled preference before the first app
        // launch. Reconcile login registration even without a toggle click.
        if enabled { setEnabled(true) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.readStatus()
                if self?.enabled == true, self?.busy == false, self?.worker == nil { self?.startWorker() }
            }
        }
    }

    private func makeProcess(_ action: String) throws -> Process {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL else {
            throw NSError(domain: "GoogleSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Python 3를 찾지 못했습니다."])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", resources.appendingPathComponent("Sync/app_bridge.py").path, action,
                             "--data-dir", dataDirectory.path, "--executable", executable.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        return process
    }

    private func privateLog() throws -> FileHandle {
        try SyncFiles.openPrivateLog(in: dataDirectory)
    }

    private func startWorker() {
        guard !demo, enabled, worker == nil, !busy else { return }
        guard FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("token.json").path)
                || FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("adc.json").path) else {
            state = "auth_required"; message = "Google 계정을 연결하세요."; return
        }
        do {
            let process = try makeProcess("loop")
            let log = try privateLog()
            process.standardOutput = log; process.standardError = log
            process.terminationHandler = { [weak self] ended in
                try? log.close()
                Task { @MainActor in
                    guard self?.worker === ended else { return }
                    self?.worker = nil
                }
            }
            try process.run()
            worker = process
            state = "running"
        } catch { message = error.localizedDescription; state = "failed" }
    }

    func stopForTermination() {
        enabled = false // Do not change the saved login preference on application quit.
        timer?.invalidate()
        operation?.terminate()
        worker?.terminate()
    }

    func setEnabled(_ value: Bool) {
        guard !demo else { enabled = value; return }
        do {
            try setLoginAgent(value)
            enabled = value
            UserDefaults.standard.set(value, forKey: "GoogleSyncEnabled")
            if value { startWorker() }
            else { worker?.terminate(); message = "자동 동기화를 일시 중지했습니다."; state = "paused" }
        } catch { message = "자동 실행 설정에 실패했습니다: \(error.localizedDescription)"; state = "failed" }
    }

    private func setLoginAgent(_ value: Bool) throws {
        let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let path = agents.appendingPathComponent("\(label).plist")
        if !value { try? FileManager.default.removeItem(at: path); return }
        guard let executable = Bundle.main.executableURL else { return }
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [executable.path, "--background"],
                                    "RunAtLoad": true, "ProcessType": "Interactive"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    func syncNow() {
        guard !busy else { return }
        if !enabled { setEnabled(true); return }
        guard let worker, worker.isRunning else { startWorker(); return }
        // A newly launched worker starts its first cycle immediately. Signal
        // only after its handler is installed; SIGUSR1 defaults to termination.
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("worker.json")),
           let ready = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           ready["pid"] as? Int == Int(worker.processIdentifier) {
            kill(worker.processIdentifier, SIGUSR1)
            state = "running"
        }
    }

    func checkConnection() { runAction("check") }

    func connect() {
        guard !busy else { return }
        if !FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("credentials.json").path) {
            let panel = NSOpenPanel()
            panel.title = "Google Desktop OAuth 인증 JSON 선택"
            panel.message = "Google Cloud에서 받은 Desktop OAuth 클라이언트 JSON을 선택하세요."
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let client = json?["installed"] as? [String: Any], client["client_id"] is String else {
                    throw NSError(domain: "GoogleSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "Desktop OAuth 클라이언트 JSON이 필요합니다."])
                }
                try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let destination = dataDirectory.appendingPathComponent("credentials.json")
                try data.write(to: destination, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } catch { message = error.localizedDescription; state = "failed"; return }
        }
        runAction("auth")
    }

    private func runAction(_ action: String) {
        guard !demo, !busy else { return }
        busy = true
        message = action == "auth" ? "브라우저에서 Google 로그인을 완료하세요." : "Google 연결을 확인하는 중…"
        let previous = worker
        previous?.terminate()
        Task {
            // Avoid racing a token refresh or sync commit with reauthorization.
            for _ in 0..<200 where previous?.isRunning == true { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard previous?.isRunning != true else { busy = false; message = "동기화가 종료될 때까지 기다린 뒤 다시 시도하세요."; return }
            do {
                let process = try makeProcess(action)
                let pipe = Pipe()
                let log = try privateLog()
                process.standardOutput = pipe; process.standardError = log
                operation = process
                try process.run()
                let result: (Data, Int32) = await Task.detached {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return (data, process.terminationStatus)
                }.value
                try? log.close()
                operation = nil
                if result.1 == 0, let payload = try JSONSerialization.jsonObject(with: result.0) as? [String: Any] {
                    state = payload["state"] as? String ?? "failed"
                    account = payload["account_email"] as? String ?? account
                    message = state == "ok" ? "Google Tasks 연결이 정상입니다." : (payload["message"] as? String ?? "연결 확인에 실패했습니다.")
                    if action == "auth", state == "ok" { setEnabled(true) }
                } else { state = "failed"; message = "연결을 완료하지 못했습니다. 다시 시도하세요." }
            } catch { state = "failed"; message = error.localizedDescription }
            busy = false
            if enabled { startWorker() }
        }
    }

    private func readStatus() {
        guard !demo, !busy else { return }
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("connection.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            account = json["account_email"] as? String ?? ""
        }
        guard enabled,
              let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("status.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        state = json["state"] as? String ?? "disconnected"
        if let time = json["last_success_at"] as? String { lastSuccess = ISO8601DateFormatter().date(from: time) }
        switch state {
        case "ok": message = "미리알림과 Google Tasks가 동기화되었습니다."
        case "running": message = "동기화하는 중…"
        case "awaiting_mutation_approval", "blocked_mutation_plan": message = "일반 변경은 동기화됩니다. 대량 삭제·완료는 확인 창에서 승인해야 반영됩니다."
        case "auth_required", "auth_timeout", "auth_prompt_open": message = "Google 로그인 연결을 다시 확인하세요."
        case "account_binding_required": message = "계정이 변경되어 동기화를 중단했습니다. 기존 Google 계정으로 연결하세요."
        default: message = "동기화에 실패했습니다. 연결과 미리알림 권한을 확인하세요."
        }
    }
}

struct GoogleSyncView: View {
    @ObservedObject var sync: GoogleSync

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Google Tasks", systemImage: "arrow.triangle.2.circlepath")
                .font(.title2.weight(.semibold))
            Text("미리알림의 제목·메모·날짜·완료 상태를 양방향으로 동기화합니다. Google Tasks에는 날짜만 반영됩니다.")
                .font(.callout).foregroundStyle(.secondary)
            if !sync.account.isEmpty { Label(sync.account, systemImage: "person.crop.circle") }
            Text(sync.message).font(.callout).textSelection(.enabled)
            if let last = sync.lastSuccess { Text("마지막 동기화: \(last.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            Toggle("자동 동기화 · 로그인 시 앱 실행", isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                .disabled(sync.busy)
            Text("창을 닫아도 메뉴 막대에서 동기화가 계속됩니다. 앱을 종료하면 다음 로그인이나 앱 실행 때 재개합니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(sync.account.isEmpty ? "Google 연결" : "다시 로그인") { sync.connect() }
                Button("연결 확인") { sync.checkConnection() }
                Button("지금 동기화") { sync.syncNow() }
                    .disabled(!sync.enabled)
                if sync.busy { ProgressView().controlSize(.small) }
            }.disabled(sync.busy)
        }
        .padding(22).frame(width: 460)
    }
}
