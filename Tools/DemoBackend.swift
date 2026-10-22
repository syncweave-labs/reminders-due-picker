// DemoBackend.swift — in-memory reminders for tests and screenshots. Never
// touches EventKit data; not part of the app bundle.

import Foundation

@MainActor
final class DemoBackend: ReminderBackend {
    let calendar: Calendar
    var onStoreChange: (() -> Void)?
    var access: AccessState = .granted
    var lists: [ReminderList]
    var items: [ReminderItem]
    /// Completed reminders backing the 완료됨 smart list.
    var completed: [ReminderItem]
    /// Makes the next `apply`/management commit fail as a whole, like a refused EventKit commit.
    var failNextCommit = false
    private var createdCount = 0

    init(now: Date, calendar: Calendar) {
        self.calendar = calendar
        let today = Day(now, calendar: calendar)
        func day(_ offset: Int) -> Day { today.adding(days: offset, calendar: calendar) }

        lists = [
            ReminderList(id: "todo", title: "할 일", accountTitle: "iCloud",
                         color: RGBColor(red: 0.04, green: 0.52, blue: 1.0), isEditable: true),
            ReminderList(id: "school", title: "학교", accountTitle: "iCloud",
                         color: RGBColor(red: 1.0, green: 0.58, blue: 0.0), isEditable: true),
            ReminderList(id: "personal", title: "개인", accountTitle: "iCloud",
                         color: RGBColor(red: 0.2, green: 0.78, blue: 0.35), isEditable: true),
            ReminderList(id: "club", title: "동아리 (공유)", accountTitle: "iCloud",
                         color: RGBColor(red: 0.69, green: 0.32, blue: 0.87), isEditable: false),
        ]

        func item(_ id: String, _ title: String, _ list: String, _ due: DueValue?,
                  recurring: Bool = false, alarms: Bool = false, editable: Bool = true,
                  notes: String = "", priority: ReminderPriority = .none) -> ReminderItem {
            ReminderItem(id: id, title: title, listID: list, due: due, hasUnreadableDue: false,
                         isRecurring: recurring, isEditable: editable, hasAlarms: alarms || due?.time != nil,
                         hasNotes: !notes.isEmpty, notes: notes, priority: priority)
        }

        items = [
            item("r-assignment", "자료구조 과제 3 제출", "school", DueValue(day(-1)),
                 notes: "3장 연결 리스트 구현 포함", priority: .high),
            item("r-quiz", "운영체제 퀴즈 준비", "school", DueValue(day(0), TimeOfDay(21, 0)), priority: .medium),
            item("r-library", "도서관 책 반납", "personal", DueValue(day(0))),
            item("r-scholarship", "장학금 서류 스캔해서 올리기", "todo", DueValue(day(1), TimeOfDay(10, 0))),
            item("r-meeting", "팀 프로젝트 회의", "school", DueValue(day(2), TimeOfDay(15, 0)), recurring: true),
            item("r-dues", "동아리 회비 정산", "club", DueValue(day(3)), editable: false),
            item("r-gym", "헬스장 재등록", "personal", DueValue(day(5))),
            item("r-study", "알고리즘 스터디 발표 자료", "school", DueValue(day(9))),
            item("r-backup", "노트북 백업하기", "todo", nil),
            item("r-trip", "겨울 여행 숙소 알아보기", "personal", nil),
            item("r-unsubscribe", "안 쓰는 구독 해지", "todo", nil),
        ]

        func done(_ id: String, _ title: String, _ list: String, _ daysAgo: Int) -> ReminderItem {
            let when = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return ReminderItem(id: id, title: title, listID: list, due: DueValue(day(-daysAgo)),
                                hasUnreadableDue: false, isRecurring: false, isEditable: true,
                                hasAlarms: false, hasNotes: false, notes: "", priority: .none,
                                isCompleted: true, completionDate: when)
        }
        completed = [
            done("c-report", "실험 보고서 제출", "school", 1),
            done("c-pay", "관리비 납부", "personal", 3),
            done("c-call", "병원 예약 전화", "todo", 10),
        ]
    }

    func accessState() -> AccessState { access }

    func requestAccess() async -> AccessState { access }

    func fetchLists() -> [ReminderList] { lists }

    func fetchReminders() async -> [ReminderItem] { items }

    func fetchCompleted(within days: Int) async -> [ReminderItem] {
        completed.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
    }

    func defaultListID() -> String? { lists.first?.id }

    func apply(_ requests: [DueChangeRequest]) -> ApplyReport {
        var report = ApplyReport()
        var previous: [(id: String, due: DueValue?, result: DueValue?)] = []
        for request in requests {
            guard let index = items.firstIndex(where: { $0.id == request.id }) else {
                report.skipped.append((request.id, .missing))
                continue
            }
            guard items[index].due == request.expected else {
                report.skipped.append((request.id, .changedElsewhere))
                continue
            }
            if !items[index].isEditable {
                report.skipped.append((request.id, .blocked(.readOnlyList)))
                continue
            }
            if request.new == nil && items[index].isRecurring {
                report.skipped.append((request.id, .blocked(.recurringNeedsDate)))
                continue
            }
            previous.append((request.id, items[index].due, request.new))
            items[index].due = request.new
            items[index].hasUnreadableDue = false
        }
        if failNextCommit {
            failNextCommit = false
            for entry in previous {
                if let index = items.firstIndex(where: { $0.id == entry.id }) { items[index].due = entry.due }
            }
            report.failure = "demo commit refused"
            return report
        }
        report.changed = previous.map(\.id)
        if !previous.isEmpty {
            report.undo = UndoAction { [weak self] in
                guard let self else { return ApplyReport(failure: "gone") }
                var undone = ApplyReport()
                for entry in previous {
                    guard let index = self.items.firstIndex(where: { $0.id == entry.id }) else {
                        undone.skipped.append((entry.id, .missing))
                        continue
                    }
                    guard self.items[index].due == entry.result else {
                        undone.skipped.append((entry.id, .changedElsewhere))
                        continue
                    }
                    self.items[index].due = entry.due
                    undone.changed.append(entry.id)
                    undone.resultingDues[entry.id] = .some(entry.due)
                }
                return undone
            }
        }
        return report
    }

    func create(title: String, listID: String?, due: DueValue?) throws -> String {
        guard let list = lists.first(where: { $0.id == (listID ?? defaultListID()) }) else {
            throw ReminderStoreError.noList
        }
        guard list.isEditable else { throw ReminderStoreError.readOnlyList }
        createdCount += 1
        let id = "new-\(createdCount)"
        items.append(ReminderItem(id: id, title: title, listID: list.id, due: due, hasUnreadableDue: false,
                                  isRecurring: false, isEditable: true, hasAlarms: due?.time != nil, hasNotes: false))
        return id
    }

    // MARK: Management writes (in-memory, same guards and batch semantics as EventKit)

    private enum Store { case active, completed }

    /// Where a reminder currently lives.
    private func locate(_ id: String) -> (store: Store, index: Int)? {
        if let index = items.firstIndex(where: { $0.id == id }) { return (.active, index) }
        if let index = completed.firstIndex(where: { $0.id == id }) { return (.completed, index) }
        return nil
    }

    private func read(_ loc: (store: Store, index: Int)) -> ReminderItem {
        loc.store == .active ? items[loc.index] : completed[loc.index]
    }

    private func write(_ loc: (store: Store, index: Int), _ item: ReminderItem) {
        if loc.store == .active { items[loc.index] = item } else { completed[loc.index] = item }
    }

    private func isEditable(_ item: ReminderItem) -> Bool {
        lists.first { $0.id == item.listID }?.isEditable ?? false
    }

    /// Shared batch skeleton: `plan` mutates a copy and returns true to keep it,
    /// or false to skip. A refused commit rolls everything back.
    private func runBatch(_ ids: [(id: String, snapshot: ReminderSnapshot)],
                          plan: (inout ReminderItem) -> Bool) -> ApplyReport {
        var report = ApplyReport()
        var undos: [(id: String, before: ReminderItem, after: ReminderItem)] = []
        for entry in ids {
            guard let loc = locate(entry.id) else { report.skipped.append((entry.id, .missing)); continue }
            let before = read(loc)
            guard ReminderSnapshot(before) == entry.snapshot else {
                report.skipped.append((entry.id, .changedElsewhere)); continue
            }
            guard isEditable(before) else { report.skipped.append((entry.id, .blocked(.readOnlyList))); continue }
            var working = before
            guard plan(&working) else { continue }
            write(loc, working)
            undos.append((entry.id, before, working))
        }
        if failNextCommit {
            failNextCommit = false
            for entry in undos { if let loc = locate(entry.id) { write(loc, entry.before) } }
            report.failure = "demo commit refused"
            return report
        }
        guard !undos.isEmpty else { return report }
        report.changed = undos.map(\.id)
        report.undo = UndoAction { [weak self] in
            guard let self else { return ApplyReport(failure: "gone") }
            var undone = ApplyReport()
            for entry in undos {
                guard let loc = self.locate(entry.id) else { undone.skipped.append((entry.id, .missing)); continue }
                guard ReminderSnapshot(self.read(loc)) == ReminderSnapshot(entry.after) else {
                    undone.skipped.append((entry.id, .changedElsewhere)); continue
                }
                self.write(loc, entry.before)
                undone.changed.append(entry.id)
            }
            // Un-completing/re-completing an item during undo moves stores back.
            self.reconcileCompletionStores(undone.changed)
            return undone
        }
        return report
    }

    func setCompleted(_ requests: [CompletionRequest]) -> ApplyReport {
        let now = Date()
        var refused: [(String, SkipReason)] = []
        let wanted = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0.complete) })
        var report = runBatch(requests.map { ($0.id, $0.expected) }) { item in
            if item.isRecurring { refused.append((item.id, .refused(recurringCompletionRefusal))); return false }
            guard let complete = wanted[item.id], item.isCompleted != complete else { return false }
            item.isCompleted = complete
            item.completionDate = complete ? now : nil
            return true
        }
        // Completing/uncompleting moves the item between the two stores.
        reconcileCompletionStores(report.changed)
        report.skipped.append(contentsOf: refused)
        return report
    }

    /// Keep an item in the store that matches its completion flag.
    private func reconcileCompletionStores(_ ids: [String]) {
        for id in ids {
            if let index = items.firstIndex(where: { $0.id == id }), items[index].isCompleted {
                completed.append(items.remove(at: index))
            } else if let index = completed.firstIndex(where: { $0.id == id }), !completed[index].isCompleted {
                items.append(completed.remove(at: index))
            }
        }
    }

    func delete(_ requests: [DeleteRequest]) -> ApplyReport {
        var report = ApplyReport()
        var toRemove: [String] = []
        for request in requests {
            guard let loc = locate(request.id) else { report.skipped.append((request.id, .missing)); continue }
            let item = read(loc)
            guard ReminderSnapshot(item) == request.expected else {
                report.skipped.append((request.id, .changedElsewhere)); continue
            }
            guard isEditable(item) else { report.skipped.append((request.id, .blocked(.readOnlyList))); continue }
            toRemove.append(request.id)
        }
        if failNextCommit { failNextCommit = false; report.failure = "demo commit refused"; return report }
        for id in toRemove {
            items.removeAll { $0.id == id }
            completed.removeAll { $0.id == id }
        }
        report.changed = toRemove // No undo.
        return report
    }

    func editFields(_ request: EditFieldsRequest) -> ApplyReport {
        runBatch([(request.id, request.expected)]) { item in
            item.title = request.newTitle
            item.notes = request.newNotes
            item.hasNotes = !request.newNotes.isEmpty
            return true
        }
    }

    func move(_ requests: [MoveRequest]) -> ApplyReport {
        let target = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0.newListID) })
        return runBatch(requests.map { ($0.id, $0.expected) }) { item in
            guard let listID = target[item.id],
                  let dest = self.lists.first(where: { $0.id == listID }), dest.isEditable,
                  item.listID != listID else { return false }
            item.listID = listID
            return true
        }
    }

    func setPriority(_ requests: [PriorityRequest]) -> ApplyReport {
        let target = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0.newPriority) })
        return runBatch(requests.map { ($0.id, $0.expected) }) { item in
            guard let priority = target[item.id], item.priority != priority else { return false }
            item.priority = priority
            return true
        }
    }
}
