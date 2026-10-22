import AppKit
import Foundation
import SwiftUI

// U09: per-list sync policy editing (A) and individual conflict review (B).
//
// Both screens reuse the app's existing SwiftUI conventions: view-local state
// lives in ObservableObjects (the @State macro plugin ships only with Xcode),
// and every remote action goes through GoogleSync.runIPC, which talks to the
// signed bridge. Saving policy only rewrites config.json; applying a conflict
// choice runs through the engine's mutation planner and destructive gate. No
// screen here writes Apple Reminders or Google Tasks directly.

// MARK: - U09-A policy editor

@MainActor
final class SyncPolicyModel: ObservableObject {
    enum Phase { case loading, ready, empty, failed, forbidden }
    struct Row: Identifiable {
        let id = UUID()
        let listTitle: String
        let present: Bool
        var direction: String
        var deletePropagation: Bool
        var syncUndated: Bool
        var conflictPolicy: String
        let inheritedDirection: String
        let overriddenKeys: [String]
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var message = ""
    @Published private(set) var rows: [Row] = []
    @Published private(set) var directions: [String] = []
    @Published private(set) var conflictPolicies: [String] = []
    @Published private(set) var nameKeyed = true
    @Published private(set) var saving = false
    private var fingerprint = ""
    private let sync: GoogleSync

    init(sync: GoogleSync) { self.sync = sync }

    /// Seed deterministic demo rows for offscreen snapshots. Never touches the
    /// bridge or any real data.
    func seedDemo() {
        directions = ["bidirectional", "apple_to_google", "google_to_apple"]
        conflictPolicies = ["skip", "newer_wins"]
        nameKeyed = true
        rows = [
            Row(listTitle: "업무", present: true, direction: "apple_to_google",
                deletePropagation: false, syncUndated: true, conflictPolicy: "skip",
                inheritedDirection: "bidirectional", overriddenKeys: ["direction", "sync_undated"]),
            Row(listTitle: "개인", present: true, direction: "bidirectional",
                deletePropagation: false, syncUndated: false, conflictPolicy: "newer_wins",
                inheritedDirection: "bidirectional", overriddenKeys: ["conflict_policy"]),
            Row(listTitle: "보관함", present: false, direction: "google_to_apple",
                deletePropagation: true, syncUndated: false, conflictPolicy: "skip",
                inheritedDirection: "bidirectional", overriddenKeys: ["direction", "delete_propagation"]),
        ]
        phase = .ready
    }

    func load() async {
        phase = .loading
        let result = await sync.runIPC("policy-read")
        apply(result, afterSave: false)
    }

    private func apply(_ result: [String: Any], afterSave: Bool) {
        guard result["ok"] as? Bool == true else {
            let state = result["state"] as? String ?? "failed"
            phase = state == "forbidden" ? .forbidden : .failed
            message = result["message"] as? String ?? "정책을 불러오지 못했습니다."
            return
        }
        fingerprint = result["fingerprint"] as? String ?? fingerprint
        directions = result["directions"] as? [String] ?? directions
        conflictPolicies = result["conflict_policies"] as? [String] ?? conflictPolicies
        nameKeyed = result["name_keyed"] as? Bool ?? true
        let lists = result["lists"] as? [[String: Any]] ?? []
        rows = lists.map { entry in
            let effective = entry["effective"] as? [String: Any] ?? [:]
            let inherited = entry["inherited"] as? [String: Any] ?? [:]
            return Row(
                listTitle: entry["list_title"] as? String ?? "",
                present: entry["present"] as? Bool ?? true,
                direction: effective["direction"] as? String ?? "bidirectional",
                deletePropagation: effective["delete_propagation"] as? Bool ?? false,
                syncUndated: effective["sync_undated"] as? Bool ?? false,
                conflictPolicy: effective["conflict_policy"] as? String ?? "skip",
                inheritedDirection: inherited["direction"] as? String ?? "bidirectional",
                overriddenKeys: entry["overridden_keys"] as? [String] ?? []
            )
        }
        phase = rows.isEmpty ? .empty : .ready
        message = afterSave ? "정책을 저장했습니다. 다음 동기화부터 적용됩니다." : ""
    }

    func binding(for id: UUID) -> Binding<Row>? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.rows[index] }, set: { self.rows[index] = $0 })
    }

    private func overridesPayload() -> [String: Any] {
        var policies: [String: Any] = [:]
        for row in rows {
            policies[row.listTitle] = [
                "direction": row.direction,
                "delete_propagation": row.deletePropagation,
                "sync_undated": row.syncUndated,
                "conflict_policy": row.conflictPolicy,
            ]
        }
        return policies
    }

    func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let result = await sync.runIPC("policy-save", input: [
            "list_policies": overridesPayload(),
            "fingerprint": fingerprint,
        ])
        if result["ok"] as? Bool == true {
            apply(result, afterSave: true)
        } else if result["state"] as? String == "policy_stale" {
            message = result["message"] as? String ?? "설정이 바뀌었습니다. 다시 불러온 뒤 저장하세요."
            await load()
        } else {
            message = result["message"] as? String ?? "정책을 저장하지 못했습니다."
        }
    }
}

struct SyncPolicyView: View {
    @ObservedObject var model: SyncPolicyModel
    var autoLoad = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("목록별 동기화 정책", systemImage: "slider.horizontal.3")
                .font(.title2.weight(.semibold))
            switch model.phase {
            case .loading:
                ProgressView("정책을 불러오는 중…").frame(maxWidth: .infinity, minHeight: 80)
            case .forbidden:
                Text("이 설정을 볼 권한이 없습니다.").foregroundStyle(.secondary)
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.message).foregroundStyle(.red)
                    Button("다시 시도") { Task { await model.load() } }
                }
            case .empty:
                Text("동기화할 미리알림 목록이 없습니다.").foregroundStyle(.secondary)
            case .ready:
                if model.nameKeyed {
                    Text("목록은 이름으로 구분됩니다. 같은 이름의 목록이나 이름을 바꾼 목록은 구별하지 못할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.rows) { row in
                            if let bind = model.binding(for: row.id) { SyncPolicyRowView(row: bind) }
                        }
                    }
                }.frame(maxHeight: 300)
                HStack {
                    if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("저장") { Task { await model.save() } }
                        .keyboardShortcut("s", modifiers: [.command])
                        .disabled(model.saving)
                    if model.saving { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(22).frame(width: 520)
        .task { if autoLoad { await model.load() } }
    }
}

struct SyncPolicyRowView: View {
    @Binding var row: SyncPolicyModel.Row

    private func directionLabel(_ value: String) -> String {
        switch value {
        case "apple_to_google": return "Apple → Google"
        case "google_to_apple": return "Google → Apple"
        default: return "양방향"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.listTitle).font(.headline)
                if !row.present { Text("(목록 없음)").font(.caption).foregroundStyle(.secondary) }
                if !row.overriddenKeys.isEmpty {
                    Text("재정의됨").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                }
            }
            Picker("동기화 방향", selection: $row.direction) {
                ForEach(["bidirectional", "apple_to_google", "google_to_apple"], id: \.self) { value in
                    Text(directionLabel(value)).tag(value)
                }
            }.pickerStyle(.menu)
            Toggle("삭제 전파", isOn: $row.deletePropagation)
            Toggle("날짜 없는 항목 포함", isOn: $row.syncUndated)
            Picker("충돌 정책", selection: $row.conflictPolicy) {
                Text("건너뛰기(검토)").tag("skip")
                Text("최신 우선").tag("newer_wins")
            }.pickerStyle(.segmented)
            Text("상속 기본값: \(directionLabel(row.inheritedDirection))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

