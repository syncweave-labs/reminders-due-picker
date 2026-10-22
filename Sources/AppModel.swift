// AppModel.swift — state and actions behind the window.

import AppKit
import Combine
import Foundation

enum ReminderFilter: Hashable {
    case all, today, overdue, scheduled, undated, completed
    case list(String)
}

enum FocusTarget: Hashable {
    case dateInput, quickAddTitle
}

struct StatusMessage: Equatable {
    enum Tone { case info, success, warning, error }

    let tone: Tone
    let text: String
    /// Offers "되돌리기" next to the message.
    let offersUndo: Bool

    init(_ tone: Tone, _ text: String, offersUndo: Bool = false) {
        self.tone = tone
        self.text = text
        self.offersUndo = offersUndo
    }
}

struct ReminderSection: Identifiable {
    let bucket: DueBucket
    let items: [ReminderItem]

    var id: Int { bucket.rawValue }
}

/// A batch delete waiting on the confirmation dialog. Holds the exact items so
/// the guard matches what the user saw, even if the list reloads underneath.
struct PendingDelete: Identifiable, Equatable {
    let id = UUID()
    let items: [ReminderItem]
    var count: Int { items.count }

    static func == (lhs: PendingDelete, rhs: PendingDelete) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var access: AccessState = .checking
    @Published private(set) var lists: [ReminderList] = []
    @Published private(set) var items: [ReminderItem] = []
    /// Reminders completed within `completedWindowDays`, for the 완료됨 smart list.
    @Published private(set) var completedItems: [ReminderItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadedOnce = false
    @Published var filter: ReminderFilter = .all
    @Published var search = ""
    @Published var selection: Set<String> = [] {
        didSet { followSelectionInCalendar(previous: oldValue) }
    }
    @Published var dateInput = ""
    @Published var displayedMonth: Day
    @Published var customTime: Date
    @Published var status: StatusMessage?
    @Published var focusRequest: FocusTarget?
    @Published var showsInspector = true
    @Published var quickAddTitle = ""
    @Published var quickAddDate = ""
    @Published var quickAddListID: String?
    /// Inspector edit draft for the single selected reminder's title and notes.
    @Published var editTitleDraft = ""
    @Published var editNotesDraft = ""
    /// Set when a batch delete is pending the confirmation dialog.
    @Published var pendingDelete: PendingDelete?
    private let completedWindowDays = 30
    /// Re-evaluated every minute so "오늘" and "지연됨" stay right while the app is open.
    @Published private(set) var clock: Date

    let backend: ReminderBackend
    private let nowProvider: () -> Date
    private var undoStack: [(label: String, action: UndoAction)] = []
    @Published private(set) var canUndo = false
    private var reloadTask: Task<Void, Never>?
    private var clockTimer: Timer?

    init(backend: ReminderBackend, now: @escaping () -> Date = Date.init, tickClock: Bool = true) {
        self.backend = backend
        self.nowProvider = now
        let start = now()
        self.clock = start
        let calendar = backend.calendar
        let today = Day(start, calendar: calendar)
        self.displayedMonth = Day(today.year, today.month, 1)
        self.customTime = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
        backend.onStoreChange = { [weak self] in self?.scheduleReload() }
        if tickClock {
            clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    var calendar: Calendar { backend.calendar }
    var today: Day { Day(clock, calendar: calendar) }
    var firstWeekday: Int { calendar.firstWeekday }

    private func tick() { clock = nowProvider() }

    // MARK: Loading

    func start() async {
        var state = backend.accessState()
        if state == .notDetermined {
            access = .checking
            state = await backend.requestAccess()
        }
        access = state
        if state == .granted { await reload() }
    }

    func reload() async {
        guard access == .granted else { return }
        isLoading = true
        let fetchedLists = backend.fetchLists()
        let fetched = await backend.fetchReminders()
        let fetchedCompleted = await backend.fetchCompleted(within: completedWindowDays)
        lists = fetchedLists
        items = fetched
        completedItems = fetchedCompleted
        let ids = Set(fetched.map(\.id)).union(fetchedCompleted.map(\.id))
        if !selection.isSubset(of: ids) { selection = selection.intersection(ids) }
        if case .list(let id) = filter, !fetchedLists.contains(where: { $0.id == id }) { filter = .all }
        if let chosen = quickAddListID, !fetchedLists.contains(where: { $0.id == chosen }) { quickAddListID = nil }
        clock = nowProvider()
        isLoading = false
        loadedOnce = true
    }

    /// Coalesces the burst of change notifications one save produces.
    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: Derived state

    func list(for item: ReminderItem) -> ReminderList? { lists.first { $0.id == item.listID } }

    func matches(_ item: ReminderItem, _ filter: ReminderFilter) -> Bool {
        switch filter {
        case .all: return true
        case .today:
            let kind = bucket(for: item.due, now: clock, calendar: calendar)
            return kind == .today || kind == .overdue
        case .overdue: return bucket(for: item.due, now: clock, calendar: calendar) == .overdue
        case .scheduled: return item.due != nil
        case .undated: return item.due == nil
        case .completed: return item.isCompleted
        case .list(let id): return item.listID == id
        }
    }

    /// The store a filter draws from: the incomplete items, or the completed ones.
    private func source(for filter: ReminderFilter) -> [ReminderItem] {
        if case .completed = filter { return completedItems }
        return items
    }

    func count(for filter: ReminderFilter) -> Int { source(for: filter).filter { matches($0, filter) }.count }

    var visibleItems: [ReminderItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return source(for: filter).filter { item in
            matches(item, filter) && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query))
        }
    }

    var sections: [ReminderSection] {
        let grouped = Dictionary(grouping: visibleItems) { bucket(for: $0.due, now: clock, calendar: calendar) }
        return DueBucket.allCases.compactMap { kind in
            guard let members = grouped[kind], !members.isEmpty else { return nil }
            return ReminderSection(bucket: kind, items: members.sorted(by: orderedBefore))
        }
    }

    private func orderedBefore(_ lhs: ReminderItem, _ rhs: ReminderItem) -> Bool {
        if let decided = dueSortsBefore(lhs.due, rhs.due) { return decided }
        let byTitle = lhs.title.localizedStandardCompare(rhs.title)
        return byTitle == .orderedSame ? lhs.id < rhs.id : byTitle == .orderedAscending
    }

    var filterTitle: String {
        switch filter {
        case .all: return "전체"
        case .today: return "오늘"
        case .overdue: return "지연됨"
        case .scheduled: return "날짜 있음"
        case .undated: return "날짜 없음"
        case .completed: return "완료됨"
        case .list(let id): return lists.first { $0.id == id }?.title ?? "목록"
        }
    }

    /// True while the 완료됨 smart list is showing. Date actions stay hidden
    /// there; completion toggling and other management actions still apply.
    var isShowingCompleted: Bool { if case .completed = filter { return true } else { return false } }

    /// The selected reminders the list is showing. A reminder hidden by the
    /// search or by the current smart list is never changed, even while it
    /// stays selected; it counts again once it is visible.
    var selectedItems: [ReminderItem] {
        visibleItems.filter { selection.contains($0.id) }.sorted(by: orderedBefore)
    }

    var hasSelection: Bool { !selectedItems.isEmpty }

    private var noTargetMessage: String {
        selection.isEmpty ? "먼저 왼쪽 목록에서 미리알림을 고르세요" : "고른 미리알림이 지금 목록에 보이지 않아요"
    }

    /// Incomplete reminders due on each day, across every list.
    var dueCounts: [Day: Int] {
        var counts: [Day: Int] = [:]
        for item in items { if let day = item.due?.day { counts[day, default: 0] += 1 } }
        return counts
    }

    var selectedDays: Set<Day> { Set(selectedItems.compactMap { $0.due?.day }) }

    /// The time every selected reminder shares (`.some(nil)` = all all-day), if they are all dated and share one.
    var sharedSelectedTime: TimeOfDay?? {
        let dues = selectedItems.map(\.due)
        guard let first = dues.first, let firstDue = first,
              dues.allSatisfy({ $0 != nil && $0?.time == firstDue.time }) else { return nil }
        return .some(firstDue.time)
    }

    func label(for item: ReminderItem) -> String {
        item.hasUnreadableDue ? "날짜 확인 필요" : dueLabel(item.due, today: today, calendar: calendar)
    }

    var parsedDateInput: ParseOutcome { parseDueText(dateInput, now: clock, calendar: calendar) }

    /// What pressing Return in the date field would do.
    var dateInputPreview: (text: String, isError: Bool)? {
        switch parsedDateInput {
        case .empty:
            return nil
        case .failure(let message):
            return (message, true)
        case .edit(let edit):
            let targets = selectedItems
            if targets.count == 1, let item = targets.first {
                let result = applyEdit(edit, to: item.due, today: today, calendar: calendar)
                return ("↩︎ " + fullDueLabel(result, today: today, calendar: calendar), false)
            }
            let summary = describeEdit(edit, today: today, calendar: calendar)
            return (targets.isEmpty ? summary : "↩︎ \(targets.count)개 → \(summary)", false)
        }
    }

    // MARK: Changing dates

    func apply(_ edit: DueEdit) {
        let targets = selectedItems
        guard !targets.isEmpty else {
            status = StatusMessage(.warning, noTargetMessage)
            return
        }
        var requests: [DueChangeRequest] = []
        var blocked: [(String, SkipReason)] = []
        var unchanged = 0
        for item in targets {
            if let reason = blockReason(for: edit, isRecurring: item.isRecurring, isEditable: item.isEditable,
                                        hasUnreadableDue: item.hasUnreadableDue) {
                blocked.append((item.id, .blocked(reason)))
                continue
            }
            let new = applyEdit(edit, to: item.due, today: today, calendar: calendar)
            if new == item.due && !item.hasUnreadableDue {
                unchanged += 1
                continue
            }
            requests.append(DueChangeRequest(id: item.id, expected: item.due, new: new))
        }
        guard !requests.isEmpty else {
            if let first = blocked.first {
                status = StatusMessage(.warning, first.1.message)
            } else {
                status = StatusMessage(.info, targets.count == 1 ? "이미 그 날짜예요" : "모두 이미 그 날짜예요")
            }
            return
        }

        let report = backend.apply(requests)
        if let failure = report.failure {
            status = StatusMessage(.error, "저장하지 못했어요: \(failure)")
            scheduleReload()
            return
        }
        let changed = Set(report.changed)
        for request in requests where changed.contains(request.id) {
            if let index = items.firstIndex(where: { $0.id == request.id }) {
                items[index].due = request.new
                items[index].hasUnreadableDue = false
            }
        }

        var summary: String
        if changed.count == 1, let request = requests.first(where: { changed.contains($0.id) }),
           let item = items.first(where: { $0.id == request.id }) {
            summary = "‘\(item.displayTitle)’ → \(fullDueLabel(request.new, today: today, calendar: calendar))"
        } else {
            summary = "\(changed.count)개 → \(describeEdit(edit, today: today, calendar: calendar))"
        }
        if unchanged > 0 { summary += " · \(unchanged)개는 이미 그 날짜" }
        if let undo = report.undo, !changed.isEmpty {
            undoStack.append((summary, undo))
            if undoStack.count > 30 { undoStack.removeFirst(undoStack.count - 30) }
            canUndo = true
        }

        let skipped = blocked + report.skipped.map { ($0.id, $0.reason) }
        if changed.isEmpty {
            status = StatusMessage(.warning, skipped.first?.1.message ?? "바꾸지 못했어요")
        } else if let first = skipped.first {
            status = StatusMessage(.warning, "\(summary) · \(skipped.count)개는 그대로: \(first.1.message)", offersUndo: true)
        } else {
            status = StatusMessage(.success, summary, offersUndo: true)
        }
        if report.skipped.contains(where: { $0.reason == .changedElsewhere || $0.reason == .missing }) {
            scheduleReload()
        }
    }

    func apply(_ preset: DuePreset) { apply(preset.edit(today: today, calendar: calendar)) }

    func pick(day: Day) { apply(DueEdit(day: .set(day))) }

    func pick(time: TimeOfDay?) { apply(DueEdit(time: time.map(TimeChange.set) ?? .clear)) }

    func pickCustomTime() { pick(time: TimeOfDay(customTime, calendar: calendar)) }

    func submitDateInput() {
        switch parsedDateInput {
        case .empty:
            status = StatusMessage(.info, "예: 내일, 금요일 오후 3시, 10/15, 3일 후, 종일, 없음")
        case .failure(let message):
            status = StatusMessage(.error, message)
        case .edit(let edit):
            guard hasSelection else {
                status = StatusMessage(.warning, noTargetMessage)
                return
            }
            apply(edit)
            dateInput = ""
        }
    }

    func undoLast() {
        guard let entry = undoStack.popLast() else {
            status = StatusMessage(.info, "되돌릴 날짜 변경이 없어요")
            return
        }
        canUndo = !undoStack.isEmpty
        let report = entry.action.run()
        for (id, due) in report.resultingDues {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].due = due
                items[index].hasUnreadableDue = false
            }
        }
        if let failure = report.failure {
            status = StatusMessage(.error, "되돌리지 못했어요: \(failure)")
        } else if report.changed.isEmpty {
            status = StatusMessage(.warning, "되돌리지 못했어요: \(report.skipped.first?.reason.message ?? "이미 바뀌었어요")")
        } else if let first = report.skipped.first {
            status = StatusMessage(.warning, "되돌렸어요 · \(report.skipped.count)개는 그대로: \(first.reason.message)")
        } else {
            status = StatusMessage(.success, "되돌렸어요: \(entry.label)")
        }
        scheduleReload()
    }

    /// ⌘Z undoes typing while a text field is being edited, and the last date change otherwise.
    func handleUndoCommand() {
        if let editor = NSApp?.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else {
            undoLast()
        }
    }

    private func followSelectionInCalendar(previous: Set<String>) {
        guard selection != previous, selection.count == 1, let id = selection.first,
              let day = items.first(where: { $0.id == id })?.due?.day else { return }
        let month = Day(day.year, day.month, 1)
        if month != displayedMonth { displayedMonth = month }
    }

    func showMonth(offset: Int) { displayedMonth = displayedMonth.adding(months: offset, calendar: calendar) }

    func showCurrentMonth() { displayedMonth = Day(today.year, today.month, 1) }

    // MARK: Managing reminders

    /// Whether a single reminder is selected and visible (title/notes editing).
    var singleSelected: ReminderItem? { selectedItems.count == 1 ? selectedItems.first : nil }

    /// Records a management report: applies the local change for the UI,
    /// pushes undo, reloads on drift, shows status. `verb` names the action.
    /// `localUpdate` mutates the cached lists for the changed ids now;
    /// `localUndo` reverses that when the undo runs.
    private func record(_ report: ApplyReport, verb: String, undoable: Bool = true,
                        localUpdate: ((Set<String>) -> Void)? = nil,
                        localUndo: ((Set<String>) -> Void)? = nil) {
        if let failure = report.failure {
            status = StatusMessage(.error, "\(verb) 실패: \(failure)")
            scheduleReload()
            return
        }
        let changedIDs = Set(report.changed)
        localUpdate?(changedIDs)
        let changed = report.changed.count
        if undoable, let undo = report.undo, changed > 0 {
            // Wrap the backend undo so the UI reflects the restored state too.
            let wrapped = UndoAction { [weak self] in
                let undone = undo.run()
                localUndo?(Set(undone.changed))
                self?.scheduleReload()
                return undone
            }
            undoStack.append(("\(verb) \(changed)개", wrapped))
            if undoStack.count > 30 { undoStack.removeFirst(undoStack.count - 30) }
            canUndo = true
        }
        if changed == 0 {
            status = StatusMessage(.warning, report.skipped.first?.reason.message ?? "\(verb)할 수 있는 항목이 없어요")
        } else if let first = report.skipped.first {
            status = StatusMessage(.warning,
                                   "\(verb) \(changed)개 · \(report.skipped.count)개는 그대로: \(first.reason.message)",
                                   offersUndo: undoable)
        } else {
            status = StatusMessage(.success, "\(verb) \(changed)개", offersUndo: undoable)
        }
        scheduleReload()
    }

    /// Mark the visible selection complete (or incomplete). Recurring reminders
    /// are refused by the backend so no occurrence is silently dropped.
    func setCompleted(_ complete: Bool) {
        let targets = selectedItems
        guard !targets.isEmpty else { status = StatusMessage(.warning, noTargetMessage); return }
        let requests = targets.map { CompletionRequest(id: $0.id, expected: ReminderSnapshot($0), complete: complete) }
        record(backend.setCompleted(requests), verb: complete ? "완료" : "완료 해제") { [weak self] ids in
            guard let self else { return }
            // Completed items leave the active list (and vice versa).
            if complete {
                for id in ids {
                    if let index = self.items.firstIndex(where: { $0.id == id }) {
                        var moved = self.items.remove(at: index)
                        moved.isCompleted = true
                        self.completedItems.insert(moved, at: 0)
                    }
                }
            } else {
                for id in ids {
                    if let index = self.completedItems.firstIndex(where: { $0.id == id }) {
                        var moved = self.completedItems.remove(at: index)
                        moved.isCompleted = false
                        moved.completionDate = nil
                        self.items.append(moved)
                    }
                }
            }
        } localUndo: { [weak self] ids in
            guard let self else { return }
            // Reverse the store move the forward step made.
            if complete {
                for id in ids {
                    if let index = self.completedItems.firstIndex(where: { $0.id == id }) {
                        var moved = self.completedItems.remove(at: index)
                        moved.isCompleted = false
                        moved.completionDate = nil
                        self.items.append(moved)
                    }
                }
            } else {
                for id in ids {
                    if let index = self.items.firstIndex(where: { $0.id == id }) {
                        var moved = self.items.remove(at: index)
                        moved.isCompleted = true
                        self.completedItems.insert(moved, at: 0)
                    }
                }
            }
        }
    }

    /// Opens the delete confirmation for the visible selection.
    func requestDelete() {
        let targets = selectedItems
        guard !targets.isEmpty else { status = StatusMessage(.warning, noTargetMessage); return }
        pendingDelete = PendingDelete(items: targets)
    }

    /// Carries out a confirmed delete. No undo; the change reaches the mirrors.
    func confirmDelete() {
        guard let pending = pendingDelete else { return }
        pendingDelete = nil
        let requests = pending.items.map { DeleteRequest(id: $0.id, expected: ReminderSnapshot($0)) }
        let report = backend.delete(requests)
        if let failure = report.failure {
            status = StatusMessage(.error, "삭제 실패: \(failure)")
        } else if report.changed.isEmpty {
            status = StatusMessage(.warning, report.skipped.first?.reason.message ?? "삭제할 수 있는 항목이 없어요")
        } else if let first = report.skipped.first {
            status = StatusMessage(.warning, "삭제 \(report.changed.count)개 · \(report.skipped.count)개는 그대로: \(first.reason.message)")
        } else {
            status = StatusMessage(.success, "삭제 \(report.changed.count)개 (되돌릴 수 없음)")
        }
        let removed = Set(report.changed)
        items.removeAll { removed.contains($0.id) }
        completedItems.removeAll { removed.contains($0.id) }
        selection = selection.subtracting(removed)
        scheduleReload()
    }

    func cancelDelete() { pendingDelete = nil }

    /// Loads the inspector edit draft from the single selected reminder.
    func loadEditDraft() {
        guard let item = singleSelected else { editTitleDraft = ""; editNotesDraft = ""; return }
        editTitleDraft = item.title
        editNotesDraft = item.notes
    }

    /// Applies a transform to the cached item with `id`, in whichever store holds it.
    private func mutateLocal(_ id: String, _ transform: (inout ReminderItem) -> Void) {
        if let index = items.firstIndex(where: { $0.id == id }) { transform(&items[index]) }
        else if let index = completedItems.firstIndex(where: { $0.id == id }) { transform(&completedItems[index]) }
    }

    /// Saves the inspector title/notes edit for the single selected reminder.
    func saveEdit() {
        guard let item = singleSelected else { status = StatusMessage(.warning, noTargetMessage); return }
        guard let title = EditFieldLimits.normalizedTitle(editTitleDraft) else {
            status = StatusMessage(.warning, "제목은 비워 둘 수 없어요")
            return
        }
        let notes = EditFieldLimits.normalizedNotes(editNotesDraft)
        guard title != item.title || notes != item.notes else {
            status = StatusMessage(.info, "바뀐 내용이 없어요")
            return
        }
        let before = item
        let request = EditFieldsRequest(id: item.id, expected: ReminderSnapshot(item), newTitle: title, newNotes: notes)
        record(backend.editFields(request), verb: "편집") { [weak self] ids in
            for id in ids { self?.mutateLocal(id) { $0.title = title; $0.notes = notes; $0.hasNotes = !notes.isEmpty } }
        } localUndo: { [weak self] ids in
            for id in ids { self?.mutateLocal(id) { $0.title = before.title; $0.notes = before.notes; $0.hasNotes = before.hasNotes } }
        }
    }

    /// Moves the visible selection to another writable list.
    func move(toList listID: String) {
        let targets = selectedItems
        guard !targets.isEmpty else { status = StatusMessage(.warning, noTargetMessage); return }
        let previous = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.listID) })
        let requests = targets.map { MoveRequest(id: $0.id, expected: ReminderSnapshot($0), newListID: listID) }
        let name = lists.first { $0.id == listID }?.title ?? "목록"
        record(backend.move(requests), verb: "‘\(name)’(으)로 이동") { [weak self] ids in
            for id in ids { self?.mutateLocal(id) { $0.listID = listID } }
        } localUndo: { [weak self] ids in
            for id in ids { if let prev = previous[id] { self?.mutateLocal(id) { $0.listID = prev } } }
        }
    }

    /// Sets the priority of the visible selection.
    func setPriority(_ priority: ReminderPriority) {
        let targets = selectedItems
        guard !targets.isEmpty else { status = StatusMessage(.warning, noTargetMessage); return }
        let previous = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.priority) })
        let requests = targets.map { PriorityRequest(id: $0.id, expected: ReminderSnapshot($0), newPriority: priority) }
        record(backend.setPriority(requests), verb: "우선순위 ‘\(priority.title)’") { [weak self] ids in
            for id in ids { self?.mutateLocal(id) { $0.priority = priority } }
        } localUndo: { [weak self] ids in
            for id in ids { if let prev = previous[id] { self?.mutateLocal(id) { $0.priority = prev } } }
        }
    }

    // MARK: Quick add

    var quickAddTargetListID: String? {
        if let chosen = quickAddListID { return chosen }
        if case .list(let id) = filter, lists.first(where: { $0.id == id })?.isEditable == true { return id }
        return backend.defaultListID() ?? lists.first(where: \.isEditable)?.id
    }

    var editableLists: [ReminderList] { lists.filter(\.isEditable) }

    /// The due date typed into quick add: nil for none, or an error message.
    var quickAddDue: Result<DueValue?, QuickAddError> {
        switch parseDueText(quickAddDate, now: clock, calendar: calendar) {
        case .empty: return .success(nil)
        case .failure(let message): return .failure(QuickAddError(message: message))
        case .edit(let edit): return .success(applyEdit(edit, to: nil, today: today, calendar: calendar))
        }
    }

    var quickAddPreview: (text: String, isError: Bool)? {
        guard !quickAddDate.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        switch quickAddDue {
        case .success(let due): return (fullDueLabel(due, today: today, calendar: calendar), false)
        case .failure(let error): return (error.message, true)
        }
    }

    func submitQuickAdd() { Task { await performQuickAdd() } }

    func performQuickAdd() async {
        let title = quickAddTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            focusRequest = .quickAddTitle
            return
        }
        let due: DueValue?
        switch quickAddDue {
        case .success(let value): due = value
        case .failure(let error):
            status = StatusMessage(.error, error.message)
            return
        }
        do {
            let id = try backend.create(title: title, listID: quickAddTargetListID, due: due)
            quickAddTitle = ""
            quickAddDate = ""
            status = StatusMessage(.success, "‘\(title)’ 추가 → \(fullDueLabel(due, today: today, calendar: calendar))")
            await reload()
            if let item = items.first(where: { $0.id == id }) {
                if !matches(item, filter) { filter = .all }
                search = ""
                selection = [id]
            }
        } catch {
            status = StatusMessage(.error, "추가하지 못했어요: \(error.localizedDescription)")
        }
    }
}

struct QuickAddError: Error, Equatable {
    let message: String
}
