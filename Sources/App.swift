// App.swift — entry point, window and menu commands.

import AppKit
import SwiftUI
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        GoogleSync.shared.start()
        if CommandLine.arguments.contains("--background") {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !GoogleSync.shared.enabled }
    func applicationWillTerminate(_ notification: Notification) { GoogleSync.shared.stopForTermination() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        return true
    }
}

@main
enum AppEntry {
    private static var instanceLock: Int32 = -1
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--sync-export" { SyncExport.run(); return }
        if CommandLine.arguments.dropFirst().first == "--sync-apply" { SyncApply.run(); return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RemindersDuePicker")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { exit(1) }
        instanceLock = open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
        DuePickerApp.main()
    }
}

struct DuePickerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel(backend: EventKitBackend())

    var body: some Scene {
        Window("미리알림 날짜", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1220, height: 880)
        .commands { DueCommands(model: model) }
        MenuBarExtra("미리알림 날짜", systemImage: "calendar.badge.clock") {
            SyncMenu(sync: .shared)
        }
    }
}

struct SyncMenu: View {
    @ObservedObject var sync: GoogleSync
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(sync.message)
        Button("미리알림 날짜 열기") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Google Tasks 설정") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            sync.showsSettings = true
        }
        Button("지금 동기화") { sync.syncNow() }.disabled(!sync.enabled || sync.busy)
        Divider()
        Button("종료") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct DueCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("실행 취소") { model.handleUndoCommand() }
                .keyboardShortcut("z", modifiers: .command)
            Button("실행 복귀") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {
            Button("새 미리알림") { model.focusRequest = .quickAddTitle }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("날짜") {
            Button("말로 입력") { model.focusRequest = .dateInput }
                .keyboardShortcut("l", modifiers: .command)
            Divider()
            Group {
                Button("오늘") { model.apply(.today) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("내일") { model.apply(.tomorrow) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("모레") { model.apply(.dayAfterTomorrow) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("이번 주말") { model.apply(.thisWeekend) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("다음 주 월요일") { model.apply(.nextMonday) }
                    .keyboardShortcut("5", modifiers: .command)
            }
            .disabled(!model.hasSelection)
            Divider()
            Group {
                Button("하루 미루기") { model.apply(.postponeDay) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("일주일 미루기") { model.apply(.postponeWeek) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("하루 당기기") { model.apply(.advanceDay) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("종일로 바꾸기") { model.pick(time: nil) }
                Button("날짜 없음") { model.apply(DuePreset.clear) }
                    .keyboardShortcut("0", modifiers: .command)
            }
            .disabled(!model.hasSelection)
            Divider()
            Button("새로 고침") { Task { await model.reload() } }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}
