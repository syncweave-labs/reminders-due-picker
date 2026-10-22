import AppKit
import Foundation
import SwiftUI

// MARK: - U09-B conflict review

@MainActor
final class ConflictReviewModel: ObservableObject {
    enum Phase { case loading, ready, empty, failed }
    struct Diff: Identifiable { let id = UUID(); let field: String; let apple: String; let google: String }
    struct Conflict: Identifiable {
        let id: String // opaque conflict id
        let listTitle: String
        let observedAt: String
        let appleRevision: String
        let googleRevision: String
        let held: Bool
        let diffs: [Diff]
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var message = ""
    @Published private(set) var conflicts: [Conflict] = []
    @Published private(set) var busyID: String?
    private let sync: GoogleSync

    init(sync: GoogleSync) { self.sync = sync }

    /// Seed deterministic demo conflicts for offscreen snapshots.
    func seedDemo() {
        conflicts = [
            Conflict(id: "demo-1", listTitle: "업무", observedAt: "2026-10-22T05:00:00Z",
                     appleRevision: "a1", googleRevision: "g1", held: false,
                     diffs: [Diff(field: "title", apple: "보고서 초안", google: "보고서 최종본"),
                             Diff(field: "due_date", apple: "2026-10-20", google: "2026-10-22")]),
            Conflict(id: "demo-2", listTitle: "개인", observedAt: "2026-10-22T05:00:00Z",
                     appleRevision: "a2", googleRevision: "g2", held: true,
                     diffs: [Diff(field: "completed", apple: "미완료", google: "완료")]),
        ]
        phase = .ready
    }

    private func stringify(_ value: Any?) -> String {
        if value == nil || value is NSNull { return "(없음)" }
        if let b = value as? Bool { return b ? "완료" : "미완료" }
        return String(describing: value!)
    }

    func load() async {
        phase = .loading
        let result = await sync.runIPC("conflict-list")
        guard result["ok"] as? Bool == true else {
            phase = .failed
            message = result["message"] as? String ?? "충돌 목록을 불러오지 못했습니다."
            return
        }
        let raw = result["conflicts"] as? [[String: Any]] ?? []
        conflicts = raw.map { entry in
            let apple = entry["apple"] as? [String: Any] ?? [:]
            let google = entry["google"] as? [String: Any] ?? [:]
            let diffs = (entry["fields"] as? [[String: Any]] ?? []).map {
                Diff(field: $0["field"] as? String ?? "",
                     apple: stringify($0["apple"]), google: stringify($0["google"]))
            }
            return Conflict(
                id: entry["conflict_id"] as? String ?? "",
                listTitle: entry["list_title"] as? String ?? "",
                observedAt: entry["observed_at"] as? String ?? "",
                appleRevision: apple["revision"] as? String ?? "",
                googleRevision: google["revision"] as? String ?? "",
                held: (entry["choice"] as? String) == "hold",
                diffs: diffs
            )
        }
        phase = conflicts.isEmpty ? .empty : .ready
        message = ""
    }

    func resolve(_ conflict: Conflict, choice: String) async {
        guard busyID == nil else { return }
        busyID = conflict.id
        defer { busyID = nil }
        let result = await sync.runIPC("conflict-apply", input: [
            "conflict_id": conflict.id,
            "choice": choice,
            "expected_revision": ["apple": conflict.appleRevision, "google": conflict.googleRevision],
            // A fresh operation id per click; a lost response is recovered by
            // the bridge's resolution journal rather than a blind re-apply.
            "operation_id": UUID().uuidString,
        ])
        switch result["state"] as? String {
        case "resolved": message = "충돌을 해결했습니다."
        case "held": message = "이 항목을 보류했습니다. 다른 항목은 계속 동기화됩니다."
        case "conflict_stale": message = "그 사이 항목이 바뀌었습니다. 최신 내용을 다시 검토하세요."
        case "conflict_gone": message = "항목이 사라졌습니다. 목록을 새로고침합니다."
        case "account_changed": message = "계정이 바뀌어 적용을 거부했습니다."
        case "blocked_mutation_plan": message = "대량 변경 안전 기준에 걸려 확인이 필요합니다."
        default: message = result["message"] as? String ?? "적용하지 못했습니다."
        }
        await load()
    }
}

struct ConflictReviewView: View {
    @ObservedObject var model: ConflictReviewModel
    var autoLoad = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("충돌 검토", systemImage: "exclamationmark.triangle")
                .font(.title2.weight(.semibold))
            switch model.phase {
            case .loading:
                ProgressView("충돌을 불러오는 중…").frame(maxWidth: .infinity, minHeight: 80)
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.message).foregroundStyle(.red)
                    Button("다시 시도") { Task { await model.load() } }
                }
            case .empty:
                Text("검토할 충돌이 없습니다. 모든 항목이 동기화되었습니다.").foregroundStyle(.secondary)
            case .ready:
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.conflicts) { conflict in
                            ConflictRowView(conflict: conflict,
                                            busy: model.busyID == conflict.id,
                                            resolve: { choice in Task { await model.resolve(conflict, choice: choice) } })
                        }
                    }
                }.frame(maxHeight: 340)
            }
        }
        .padding(22).frame(width: 560)
        .task { if autoLoad { await model.load() } }
    }
}

struct ConflictRowView: View {
    let conflict: ConflictReviewModel.Conflict
    let busy: Bool
    let resolve: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(conflict.listTitle).font(.headline)
                if conflict.held {
                    Text("보류됨").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2)).clipShape(Capsule())
                }
                Spacer()
                if !conflict.observedAt.isEmpty {
                    Text(conflict.observedAt).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(conflict.diffs) { diff in
                HStack(alignment: .top, spacing: 8) {
                    Text(fieldLabel(diff.field)).font(.caption).frame(width: 60, alignment: .leading)
                    VStack(alignment: .leading) {
                        Text("Apple: \(diff.apple)").font(.caption)
                        Text("Google: \(diff.google)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Apple 선택") { resolve("apple") }.disabled(busy)
                Button("Google 선택") { resolve("google") }.disabled(busy)
                Button("보류") { resolve("hold") }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    private func fieldLabel(_ field: String) -> String {
        switch field {
        case "title": return "제목"
        case "notes": return "메모"
        case "due_date": return "날짜"
        case "completed": return "완료"
        default: return field
        }
    }
}
