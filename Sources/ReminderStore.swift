// ReminderStore.swift — reads and writes Apple Reminders through EventKit.
//
// Only a reminder's due date, the start date that mirrors it, and the clock
// alarms anchored to it are ever changed; title, notes, list, priority,
// recurrence and every other alarm stay as they are.

import CoreGraphics
import EventKit
import Foundation

struct RGBColor: Hashable {
    var red: Double
    var green: Double
    var blue: Double

    static let fallback = RGBColor(red: 0.56, green: 0.56, blue: 0.58)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: CGColor?) {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else {
            self = .fallback
            return
        }
        self.init(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }
}

struct ReminderList: Identifiable, Hashable {
    let id: String
    let title: String
    let accountTitle: String
    let color: RGBColor
    let isEditable: Bool
}

struct ReminderItem: Identifiable, Hashable {
    let id: String
    var title: String
    var listID: String
    var due: DueValue?
    /// Due components exist but cannot be read; only an explicit day or "no date" replaces them.
    var hasUnreadableDue: Bool
    var isRecurring: Bool
    var isEditable: Bool
    var hasAlarms: Bool
    var hasNotes: Bool
    var notes: String
    var priority: ReminderPriority
    /// True only for items from the 완료됨 smart list.
    var isCompleted: Bool
    /// Set for completed items; nil otherwise.
    var completionDate: Date?

    init(id: String, title: String, listID: String, due: DueValue?, hasUnreadableDue: Bool,
         isRecurring: Bool, isEditable: Bool, hasAlarms: Bool, hasNotes: Bool,
         notes: String = "", priority: ReminderPriority = .none,
         isCompleted: Bool = false, completionDate: Date? = nil) {
        self.id = id
        self.title = title
        self.listID = listID
        self.due = due
        self.hasUnreadableDue = hasUnreadableDue
        self.isRecurring = isRecurring
        self.isEditable = isEditable
        self.hasAlarms = hasAlarms
        self.hasNotes = hasNotes
        self.notes = notes
        self.priority = priority
        self.isCompleted = isCompleted
        self.completionDate = completionDate
    }

    var displayTitle: String { title.isEmpty ? "(제목 없음)" : title }
}

/// The four Reminders priority buckets. EventKit stores an Int 0–9; Apple's own
/// app writes 1 (high), 5 (medium), 9 (low) and reads any 1–4 as high, 5 as
/// medium, 6–9 as low. `fromEventKit`/`eventKitValue` keep that mapping so the
/// app never rewrites a value Reminders set to something it would display
/// differently.
enum ReminderPriority: Int, Hashable, CaseIterable, Identifiable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: return "없음"
        case .low: return "낮음"
        case .medium: return "중간"
        case .high: return "높음"
        }
    }

    /// EventKit's own stored integer for this bucket (what Apple's app writes).
    var eventKitValue: Int {
        switch self {
        case .none: return 0
        case .low: return 9
        case .medium: return 5
        case .high: return 1
        }
    }

    /// Reads any EventKit integer the way Apple's app displays it.
    static func fromEventKit(_ value: Int) -> ReminderPriority {
        switch value {
        case 0: return .none
        case 1...4: return .high
        case 5: return .medium
        default: return .low
        }
    }
}

enum AccessState: Equatable {
    case checking
    case notDetermined
    case granted
    case denied
    case restricted
    case failed(String)
}

struct DueChangeRequest: Hashable {
    let id: String
    /// The due value the edit was computed from. A reminder that no longer has
    /// it was changed somewhere else in the meantime and is left alone.
    let expected: DueValue?
    let new: DueValue?
}

// MARK: - Management requests (complete, delete, edit, move, priority)

/// A fingerprint of the fields a management action may read, taken when the
/// list was loaded. The backend refuses to act on a reminder whose matching
/// fields changed since — the same "left alone if it changed elsewhere" guard
/// the date apply uses, widened to the fields each action touches.
struct ReminderSnapshot: Hashable {
    let title: String
    let notes: String
    let listID: String
    let priority: ReminderPriority
    let due: DueValue?
    let hasUnreadableDue: Bool

    init(_ item: ReminderItem) {
        title = item.title
        notes = item.notes
        listID = item.listID
        priority = item.priority
        due = item.due
        hasUnreadableDue = item.hasUnreadableDue
    }
}

struct CompletionRequest: Hashable {
    let id: String
    let expected: ReminderSnapshot
    /// true → mark completed; false → mark incomplete.
    let complete: Bool
}

struct DeleteRequest: Hashable {
    let id: String
    let expected: ReminderSnapshot
}

struct EditFieldsRequest: Hashable {
    let id: String
    let expected: ReminderSnapshot
    let newTitle: String
    let newNotes: String
}

struct MoveRequest: Hashable {
    let id: String
    let expected: ReminderSnapshot
    let newListID: String
}

struct PriorityRequest: Hashable {
    let id: String
    let expected: ReminderSnapshot
    let newPriority: ReminderPriority
}

/// Caps and trimming the edit action enforces before it reaches the store.
enum EditFieldLimits {
    static let maxTitle = 1000
    static let maxNotes = 20_000

    /// Returns a trimmed, length-capped title, or nil when it is empty after trimming.
    static func normalizedTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTitle))
    }

    static func normalizedNotes(_ raw: String) -> String {
        String(raw.prefix(maxNotes))
    }
}

enum SkipReason: Hashable {
    case missing
    case changedElsewhere
    case blocked(EditBlock)
    case failed(String)
    /// A management action refused this item for a stated reason (e.g. a
    /// recurring reminder whose safe completion cannot be proven).
    case refused(String)

    var message: String {
        switch self {
        case .missing: return "이미 완료되었거나 삭제된 미리알림이에요"
        case .changedElsewhere: return "다른 곳에서 먼저 바뀌어 그대로 두었어요"
        case .blocked(let reason): return reason.message
        case .failed(let message): return "저장하지 못했어요 (\(message))"
        case .refused(let message): return message
        }
    }
}

/// The recurring-completion refusal message. EventKit advances a recurring
/// reminder's due date to the next occurrence when it is completed through the
/// store; it cannot be proven safe on an unsaved in-memory object (which is all
/// the tests may touch) without reaching the real store, so the app refuses to
/// complete recurring reminders and says why rather than risk dropping an
/// occurrence.
let recurringCompletionRefusal =
    "반복 미리알림은 이 앱에서 완료할 수 없어요. 다음 반복이 사라지지 않도록 미리알림 앱에서 완료하세요."

struct ApplyReport {
    var changed: [String] = []
    var skipped: [(id: String, reason: SkipReason)] = []
    /// Nothing was saved because the store refused the whole commit.
    var failure: String?
    var undo: UndoAction?
    /// The due value each changed reminder has now (filled by undo).
    var resultingDues: [String: DueValue?] = [:]
}

@MainActor
final class UndoAction {
    private let body: () -> ApplyReport

    init(_ body: @escaping () -> ApplyReport) { self.body = body }

    func run() -> ApplyReport { body() }
}

enum ReminderStoreError: LocalizedError {
    case noList
    case readOnlyList

    var errorDescription: String? {
        switch self {
        case .noList: return "미리알림을 넣을 목록이 없어요"
        case .readOnlyList: return "읽기 전용 목록에는 추가할 수 없어요"
        }
    }
}

@MainActor
protocol ReminderBackend: AnyObject {
    var calendar: Calendar { get }
    /// Called on the main actor whenever the underlying store changed.
    var onStoreChange: (() -> Void)? { get set }
    func accessState() -> AccessState
    func requestAccess() async -> AccessState
    func fetchLists() -> [ReminderList]
    func fetchReminders() async -> [ReminderItem]
    func defaultListID() -> String?
    func apply(_ requests: [DueChangeRequest]) -> ApplyReport
    func create(title: String, listID: String?, due: DueValue?) throws -> String
    /// Reminders completed within the last `days`, newest first. Used by the
    /// 완료됨 smart list so un-completing is reachable.
    func fetchCompleted(within days: Int) async -> [ReminderItem]
    /// Mark complete/incomplete as one batch. Recurring reminders are refused
    /// (see `recurringCompletionRefusal`). Undo reverses the change.
    func setCompleted(_ requests: [CompletionRequest]) -> ApplyReport
    /// Delete as one batch. No undo: deletion reaches the mirrors on sync.
    func delete(_ requests: [DeleteRequest]) -> ApplyReport
    /// Edit one reminder's title and notes. Undo restores both.
    func editFields(_ request: EditFieldsRequest) -> ApplyReport
    /// Move reminders to another writable list as one batch. Undo moves back.
    func move(_ requests: [MoveRequest]) -> ApplyReport
    /// Set priority as one batch. Undo restores each previous priority.
    func setPriority(_ requests: [PriorityRequest]) -> ApplyReport
}

// MARK: - Moving one reminder (pure EventKit object edits, no saving)

/// What one date change did to a reminder: enough to put it back exactly.
struct DueChangeRecord {
    let previousDue: DateComponents?
    let previousStart: DateComponents?
    let removedAlarms: [EKAlarm]
    let addedAlarmDates: [Date]
    let resultingDue: DueValue?
}

private func isClockAlarm(_ alarm: EKAlarm) -> Bool {
    alarm.absoluteDate != nil && alarm.structuredLocation == nil
}

/// Moves a reminder's due date in memory; the caller saves. Clock alarms
/// anchored to the old due date and a start date that mirrored it follow the
/// move (see `planAlarms` and `planStart`). EventKit itself fills an empty
/// start with the new due date, as Reminders does.
func moveDue(of reminder: EKReminder, to newDue: DueValue?, calendar: Calendar) -> DueChangeRecord {
    let previousDue = reminder.dueDateComponents
    let previousStart = reminder.startDateComponents
    let oldDue = DueValue(components: previousDue, calendar: calendar)
    let clockAlarms = (reminder.alarms ?? []).filter(isClockAlarm)
    let alarmPlan = planAlarms(oldDue: oldDue, newDue: newDue,
                               absoluteAlarms: clockAlarms.compactMap(\.absoluteDate), calendar: calendar)

    reminder.dueDateComponents = newDue?.components(calendar: calendar, previous: previousDue)

    switch planStart(start: DueValue(components: previousStart, calendar: calendar),
                     oldDue: oldDue, newDue: newDue, calendar: calendar) {
    case .keep:
        break
    case .clear:
        reminder.startDateComponents = nil
    case .set(let value):
        reminder.startDateComponents = startComponents(for: value, previous: previousStart, calendar: calendar)
    }

    var removed: [EKAlarm] = []
    for index in alarmPlan.remove where clockAlarms.indices.contains(index) {
        let alarm = clockAlarms[index]
        if let copy = alarm.copy() as? EKAlarm { removed.append(copy) }
        reminder.removeAlarm(alarm)
    }
    for date in alarmPlan.add {
        reminder.addAlarm(EKAlarm(absoluteDate: date))
    }
    return DueChangeRecord(previousDue: previousDue, previousStart: previousStart,
                           removedAlarms: removed, addedAlarmDates: alarmPlan.add, resultingDue: newDue)
}

/// Reverses `moveDue` in memory; the caller saves. The start is written after
/// the due date because EventKit fills an empty start when a due date is set.
func restoreDue(of reminder: EKReminder, from record: DueChangeRecord) {
    reminder.dueDateComponents = record.previousDue
    reminder.startDateComponents = record.previousStart
    for date in record.addedAlarmDates {
        let match = (reminder.alarms ?? []).first { alarm in
            guard isClockAlarm(alarm), let when = alarm.absoluteDate else { return false }
            return abs(when.timeIntervalSince(date)) < alarmMatchTolerance
        }
        if let match { reminder.removeAlarm(match) }
    }
    for alarm in record.removedAlarms {
        if let copy = alarm.copy() as? EKAlarm { reminder.addAlarm(copy) }
    }
}

// MARK: - Pure management edits (unsaved EventKit object changes; the caller saves)

/// What one title/notes edit changed, enough to put it back exactly.
struct FieldsEditRecord {
    let previousTitle: String
    let previousNotes: String?
}

/// Sets a reminder's title and notes in memory. Date fields are never touched.
func applyFields(to reminder: EKReminder, title: String, notes: String) -> FieldsEditRecord {
    let record = FieldsEditRecord(previousTitle: reminder.title ?? "", previousNotes: reminder.notes)
    reminder.title = title
    reminder.notes = notes.isEmpty ? nil : notes
    return record
}

func restoreFields(of reminder: EKReminder, from record: FieldsEditRecord) {
    reminder.title = record.previousTitle
    reminder.notes = record.previousNotes
}

/// What one priority change was, enough to restore it.
struct PriorityEditRecord {
    let previousPriority: Int
}

func applyPriority(to reminder: EKReminder, _ priority: ReminderPriority) -> PriorityEditRecord {
    let record = PriorityEditRecord(previousPriority: reminder.priority)
    // Only rewrite when the displayed bucket actually changes, so a value
    // Reminders set inside a bucket (e.g. 2 → high) is left as-is.
    if ReminderPriority.fromEventKit(reminder.priority) != priority {
        reminder.priority = priority.eventKitValue
    }
    return record
}

func restorePriority(of reminder: EKReminder, from record: PriorityEditRecord) {
    reminder.priority = record.previousPriority
}

/// Marks a reminder completed/incomplete in memory. Date, title, notes, list
/// and priority are untouched; only the completion flag and its date move.
struct CompletionEditRecord {
    let wasCompleted: Bool
    let previousCompletionDate: Date?
}

func applyCompletion(to reminder: EKReminder, complete: Bool, now: Date) -> CompletionEditRecord {
    let record = CompletionEditRecord(wasCompleted: reminder.isCompleted,
                                      previousCompletionDate: reminder.completionDate)
    if complete {
        // Set the flag first: EventKit stamps completionDate = now when
        // isCompleted flips true, so write the intended date afterward.
        reminder.isCompleted = true
        reminder.completionDate = now
    } else {
        // Clearing the completion date first keeps EventKit from leaving a
        // stale date on an "incomplete" reminder.
        reminder.isCompleted = false
        reminder.completionDate = nil
    }
    return record
}

func restoreCompletion(of reminder: EKReminder, from record: CompletionEditRecord) {
    if record.wasCompleted {
        reminder.isCompleted = true
        reminder.completionDate = record.previousCompletionDate
    } else {
        reminder.isCompleted = false
        reminder.completionDate = nil
    }
}

// MARK: - EventKit backend

@MainActor
final class EventKitBackend: ReminderBackend {
    private let store = EKEventStore()
    private var remindersByID: [String: EKReminder] = [:]
    private var changeObserver: NSObjectProtocol?
    var onStoreChange: (() -> Void)?

    /// EventKit re-expresses due and start components in the process time
    /// zone, so the components this app builds must use the process's own
    /// calendar. A calendar pinned to another zone would shift wall times and
    /// even all-day dates when EventKit normalizes them.
    var calendar: Calendar { Calendar.autoupdatingCurrent }

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onStoreChange?() }
        }
    }

    func accessState() -> AccessState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied, .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> AccessState {
        do {
            let granted = try await store.requestFullAccessToReminders()
            if granted { store.reset() }
            return granted ? .granted : accessState()
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func fetchLists() -> [ReminderList] {
        store.calendars(for: .reminder)
            .map { list in
                ReminderList(id: list.calendarIdentifier, title: list.title,
                             accountTitle: list.source?.title ?? "", color: RGBColor(list.cgColor),
                             isEditable: list.allowsContentModifications)
            }
            .sorted { lhs, rhs in
                let byTitle = lhs.title.localizedStandardCompare(rhs.title)
                return byTitle == .orderedSame ? lhs.id < rhs.id : byTitle == .orderedAscending
            }
    }

    func fetchReminders() async -> [ReminderItem] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        let calendar = self.calendar
        var byID: [String: EKReminder] = [:]
        var items: [ReminderItem] = []
        for reminder in fetched where !reminder.isCompleted {
            let id = reminder.calendarItemIdentifier
            guard !id.isEmpty, byID[id] == nil else { continue }
            byID[id] = reminder
            let due = DueValue(components: reminder.dueDateComponents, calendar: calendar)
            items.append(ReminderItem(
                id: id,
                title: reminder.title ?? "",
                listID: reminder.calendar?.calendarIdentifier ?? "",
                due: due,
                hasUnreadableDue: reminder.dueDateComponents != nil && due == nil,
                isRecurring: reminder.hasRecurrenceRules,
                isEditable: reminder.calendar?.allowsContentModifications ?? false,
                hasAlarms: reminder.hasAlarms,
                hasNotes: reminder.hasNotes,
                notes: reminder.notes ?? "",
                priority: ReminderPriority.fromEventKit(reminder.priority)
            ))
        }
        remindersByID = byID
        return items
    }

    func defaultListID() -> String? {
        store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    /// The latest stored version of a reminder, or nil once it is gone.
    private func lookup(_ id: String) -> EKReminder? {
        if let cached = remindersByID[id], cached.refresh() { return cached }
        guard let fresh = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        remindersByID[id] = fresh
        return fresh
    }

    func apply(_ requests: [DueChangeRequest]) -> ApplyReport {
        var report = ApplyReport()
        var saved: [(id: String, record: DueChangeRecord)] = []
        let calendar = self.calendar
        for request in requests {
            guard let reminder = lookup(request.id), !reminder.isCompleted else {
                report.skipped.append((request.id, .missing))
                continue
            }
            let current = DueValue(components: reminder.dueDateComponents, calendar: calendar)
            guard current == request.expected else {
                report.skipped.append((request.id, .changedElsewhere))
                continue
            }
            if reminder.calendar?.allowsContentModifications == false {
                report.skipped.append((request.id, .blocked(.readOnlyList)))
                continue
            }
            if request.new == nil, reminder.hasRecurrenceRules {
                report.skipped.append((request.id, .blocked(.recurringNeedsDate)))
                continue
            }
            let unreadable = reminder.dueDateComponents != nil && current == nil
            guard current != request.new || unreadable else { continue }

            let record = moveDue(of: reminder, to: request.new, calendar: calendar)
            do {
                try store.save(reminder, commit: false)
                saved.append((request.id, record))
            } catch {
                reminder.rollback()
                report.skipped.append((request.id, .failed(error.localizedDescription)))
            }
        }
        guard !saved.isEmpty else { return report }
        do {
            try store.commit()
        } catch {
            store.reset()
            remindersByID = [:]
            report.failure = error.localizedDescription
            return report
        }
        report.changed = saved.map(\.id)
        report.undo = UndoAction { [weak self] in
            guard let self else { return ApplyReport(failure: "앱 상태가 바뀌어 되돌릴 수 없어요") }
            return self.restore(saved)
        }
        return report
    }

    private func restore(_ entries: [(id: String, record: DueChangeRecord)]) -> ApplyReport {
        var report = ApplyReport()
        var restored: [String] = []
        let calendar = self.calendar
        for entry in entries {
            guard let reminder = lookup(entry.id) else {
                report.skipped.append((entry.id, .missing))
                continue
            }
            guard DueValue(components: reminder.dueDateComponents, calendar: calendar) == entry.record.resultingDue else {
                report.skipped.append((entry.id, .changedElsewhere))
                continue
            }
            restoreDue(of: reminder, from: entry.record)
            do {
                try store.save(reminder, commit: false)
                restored.append(entry.id)
                report.resultingDues[entry.id] = .some(DueValue(components: entry.record.previousDue, calendar: calendar))
            } catch {
                reminder.rollback()
                report.skipped.append((entry.id, .failed(error.localizedDescription)))
            }
        }
        guard !restored.isEmpty else { return report }
        do {
            try store.commit()
        } catch {
            store.reset()
            remindersByID = [:]
            report.failure = error.localizedDescription
            report.resultingDues = [:]
            return report
        }
        report.changed = restored
        return report
    }

    func create(title: String, listID: String?, due: DueValue?) throws -> String {
        let target = listID.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewReminders()
        guard let target else { throw ReminderStoreError.noList }
        guard target.allowsContentModifications else { throw ReminderStoreError.readOnlyList }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = target
        if let due {
            // Same rules as a move from "no date": a timed reminder gets its alarm.
            _ = moveDue(of: reminder, to: due, calendar: calendar)
        }
        try store.save(reminder, commit: true)
        remindersByID[reminder.calendarItemIdentifier] = reminder
        return reminder.calendarItemIdentifier
    }

    // MARK: Management reads and writes

    func fetchCompleted(within days: Int) async -> [ReminderItem] {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -max(days, 0), to: end) ?? end
        let predicate = store.predicateForCompletedReminders(
            withCompletionDateStarting: start, ending: end, calendars: nil)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        let calendar = self.calendar
        var items: [ReminderItem] = []
        for reminder in fetched where reminder.isCompleted {
            let id = reminder.calendarItemIdentifier
            guard !id.isEmpty else { continue }
            remindersByID[id] = reminder
            let due = DueValue(components: reminder.dueDateComponents, calendar: calendar)
            items.append(ReminderItem(
                id: id,
                title: reminder.title ?? "",
                listID: reminder.calendar?.calendarIdentifier ?? "",
                due: due,
                hasUnreadableDue: reminder.dueDateComponents != nil && due == nil,
                isRecurring: reminder.hasRecurrenceRules,
                isEditable: reminder.calendar?.allowsContentModifications ?? false,
                hasAlarms: reminder.hasAlarms,
                hasNotes: reminder.hasNotes,
                notes: reminder.notes ?? "",
                priority: ReminderPriority.fromEventKit(reminder.priority),
                isCompleted: true,
                completionDate: reminder.completionDate
            ))
        }
        return items.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
    }

    /// The reminder's current fields as a snapshot, for the staleness guard.
    private func currentSnapshot(_ reminder: EKReminder) -> ReminderSnapshot {
        let due = DueValue(components: reminder.dueDateComponents, calendar: calendar)
        return ReminderSnapshot(ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            listID: reminder.calendar?.calendarIdentifier ?? "",
            due: due,
            hasUnreadableDue: reminder.dueDateComponents != nil && due == nil,
            isRecurring: reminder.hasRecurrenceRules,
            isEditable: reminder.calendar?.allowsContentModifications ?? false,
            hasAlarms: reminder.hasAlarms,
            hasNotes: reminder.hasNotes,
            notes: reminder.notes ?? "",
            priority: ReminderPriority.fromEventKit(reminder.priority)))
    }

    /// Shared batch-save skeleton for the management writes. `plan` edits the
    /// reminder in memory and returns a restore closure, or nil to skip it (it
    /// appends its own skip reason). Nothing is saved unless the whole commit
    /// succeeds; a refused commit changes nothing.
    private func runBatch(ids: [(id: String, snapshot: ReminderSnapshot)],
                          plan: (EKReminder) -> (() -> Void)?) -> ApplyReport {
        var report = ApplyReport()
        var undos: [(id: String, restore: () -> Void, after: ReminderSnapshot)] = []
        for entry in ids {
            guard let reminder = lookup(entry.id) else {
                report.skipped.append((entry.id, .missing)); continue
            }
            guard currentSnapshot(reminder) == entry.snapshot else {
                report.skipped.append((entry.id, .changedElsewhere)); continue
            }
            if reminder.calendar?.allowsContentModifications == false {
                report.skipped.append((entry.id, .blocked(.readOnlyList))); continue
            }
            guard let restore = plan(reminder) else { continue }
            do {
                try store.save(reminder, commit: false)
                undos.append((entry.id, restore, currentSnapshot(reminder)))
            } catch {
                reminder.rollback()
                report.skipped.append((entry.id, .failed(error.localizedDescription)))
            }
        }
        guard !undos.isEmpty else { return report }
        do {
            try store.commit()
        } catch {
            store.reset(); remindersByID = [:]
            report.failure = error.localizedDescription
            return report
        }
        report.changed = undos.map(\.id)
        report.undo = UndoAction { [weak self] in
            guard let self else { return ApplyReport(failure: "앱 상태가 바뀌어 되돌릴 수 없어요") }
            return self.restoreBatch(undos)
        }
        return report
    }

    private func restoreBatch(_ entries: [(id: String, restore: () -> Void, after: ReminderSnapshot)]) -> ApplyReport {
        var report = ApplyReport()
        var restored: [String] = []
        for entry in entries {
            guard let reminder = lookup(entry.id) else {
                report.skipped.append((entry.id, .missing)); continue
            }
            guard currentSnapshot(reminder) == entry.after else {
                report.skipped.append((entry.id, .changedElsewhere)); continue
            }
            entry.restore()
            do {
                try store.save(reminder, commit: false)
                restored.append(entry.id)
            } catch {
                reminder.rollback()
                report.skipped.append((entry.id, .failed(error.localizedDescription)))
            }
        }
        guard !restored.isEmpty else { return report }
        do {
            try store.commit()
        } catch {
            store.reset(); remindersByID = [:]
            report.failure = error.localizedDescription
            return report
        }
        report.changed = restored
        return report
    }

    func setCompleted(_ requests: [CompletionRequest]) -> ApplyReport {
        let now = Date()
        var refused: [(String, SkipReason)] = []
        let batch: [(id: String, snapshot: ReminderSnapshot)] = requests.map { ($0.id, $0.expected) }
        let wanted = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0.complete) })
        var report = runBatch(ids: batch) { reminder in
            // Never silently drop a recurrence: completing a recurring reminder
            // through EventKit advances it to the next occurrence, which cannot
            // be proven safe on the objects the tests may touch, so refuse it.
            if reminder.hasRecurrenceRules {
                refused.append((reminder.calendarItemIdentifier, .refused(recurringCompletionRefusal)))
                return nil
            }
            guard let complete = wanted[reminder.calendarItemIdentifier],
                  reminder.isCompleted != complete else { return nil }
            let record = applyCompletion(to: reminder, complete: complete, now: now)
            return { restoreCompletion(of: reminder, from: record) }
        }
        report.skipped.append(contentsOf: refused)
        return report
    }

    func delete(_ requests: [DeleteRequest]) -> ApplyReport {
        var report = ApplyReport()
        var removed: [String] = []
        for request in requests {
            guard let reminder = lookup(request.id) else {
                report.skipped.append((request.id, .missing)); continue
            }
            guard currentSnapshot(reminder) == request.expected else {
                report.skipped.append((request.id, .changedElsewhere)); continue
            }
            if reminder.calendar?.allowsContentModifications == false {
                report.skipped.append((request.id, .blocked(.readOnlyList))); continue
            }
            do {
                try store.remove(reminder, commit: false)
                removed.append(request.id)
            } catch {
                report.skipped.append((request.id, .failed(error.localizedDescription)))
            }
        }
        guard !removed.isEmpty else { return report }
        do {
            try store.commit()
        } catch {
            store.reset(); remindersByID = [:]
            report.failure = error.localizedDescription
            return report
        }
        for id in removed { remindersByID[id] = nil }
        report.changed = removed // No undo: deletion reaches the mirrors on sync.
        return report
    }

    func editFields(_ request: EditFieldsRequest) -> ApplyReport {
        runBatch(ids: [(request.id, request.expected)]) { reminder in
            let record = applyFields(to: reminder, title: request.newTitle, notes: request.newNotes)
            return { restoreFields(of: reminder, from: record) }
        }
    }

    func move(_ requests: [MoveRequest]) -> ApplyReport {
        let target = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0.newListID) })
        let batch: [(id: String, snapshot: ReminderSnapshot)] = requests.map { ($0.id, $0.expected) }
        return runBatch(ids: batch) { reminder in
            guard let listID = target[reminder.calendarItemIdentifier],
                  let destination = self.store.calendar(withIdentifier: listID) else { return nil }
            guard destination.allowsContentModifications else { return nil }
            guard reminder.calendar?.calendarIdentifier != listID else { return nil }
            let previous = reminder.calendar
            reminder.calendar = destination
            return { reminder.calendar = previous }
        }
    }

    func setPriority(_ requests: [PriorityRequest]) -> ApplyReport {
        let target = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0.newPriority) })
        let batch: [(id: String, snapshot: ReminderSnapshot)] = requests.map { ($0.id, $0.expected) }
        return runBatch(ids: batch) { reminder in
            guard let priority = target[reminder.calendarItemIdentifier] else { return nil }
            guard ReminderPriority.fromEventKit(reminder.priority) != priority else { return nil }
            let record = applyPriority(to: reminder, priority)
            return { restorePriority(of: reminder, from: record) }
        }
    }
}
