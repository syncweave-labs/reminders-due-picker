// macOS-only tests: the EventKit edit path on unsaved in-memory reminders
// (nothing is ever saved to a store) and the app model against DemoBackend.

import EventKit
import Foundation

@MainActor
final class Checker {
    var passed = 0
    var failed = 0

    func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("FAIL line \(line): \(message())")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "", line: Int = #line) {
        expect(actual == expected, "\(label) expected \(expected), got \(actual)", line: line)
    }
}

@main
enum AppTests {
    @MainActor
    static func main() async {
        // EventKit re-expresses due and start components in the process time
        // zone, and every expectation below is written for Asia/Seoul. Pin the
        // process zone before any EventKit object exists so the tests mean the
        // same thing on every machine; CI runners use UTC.
        setenv("TZ", "Asia/Seoul", 1)
        tzset()
        NSTimeZone.resetSystemTimeZone()
        NSTimeZone.default = TimeZone(identifier: "Asia/Seoul")!
        let check = Checker()
        check.equal(TimeZone.current.identifier, "Asia/Seoul", "process zone pinned for EventKit")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.locale = Locale(identifier: "ko_KR")
        calendar.firstWeekday = 1
        eventKitTests(check, calendar)
        await modelTests(check, calendar)
        await manageModelTests(check, calendar)
        manageEventKitTests(check, calendar)
        loginAgentTests(check)
        notionStatusTests(check)
        privateLogTests(check)
        print("App tests: \(check.passed) passed, \(check.failed) failed")
        exit(check.failed == 0 ? 0 : 1)
    }

    static func at(_ calendar: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @MainActor
    static func privateLogTests(_ check: Checker) {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: scratch) }
        do {
            let handle = try SyncFiles.openPrivateLog(in: scratch)
            try handle.write(contentsOf: Data("synthetic private title".utf8)); try handle.close()
            let log = scratch.appendingPathComponent("sync.log")
            check.equal(try fm.attributesOfItem(atPath: scratch.path)[.posixPermissions] as? Int, 0o700, "private sync directory")
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
            let rotated = try SyncFiles.openPrivateLog(in: scratch, maxBytes: 4); try rotated.close()
            check.equal(try fm.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int, 0o600, "private current log")
            check.equal(try fm.attributesOfItem(atPath: scratch.appendingPathComponent("sync.log.1").path)[.posixPermissions] as? Int, 0o600, "private rotated log")
            let victim = scratch.appendingPathComponent("victim")
            try Data("untouched".utf8).write(to: victim)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: victim.path)
            try fm.removeItem(at: log)
            try fm.createSymbolicLink(at: log, withDestinationURL: victim)
            do { let linked = try SyncFiles.openPrivateLog(in: scratch); try linked.close(); check.expect(false, "refuse linked log") }
            catch { check.expect(true, "refused linked log") }
            check.equal(try String(contentsOf: victim, encoding: .utf8), "untouched", "link target untouched")
            check.equal(try fm.attributesOfItem(atPath: victim.path)[.posixPermissions] as? Int, 0o644, "link target mode untouched")
        } catch { check.expect(false, "private log test: \(error)") }
    }

    @MainActor
    static func eventKitTests(_ check: Checker, _ calendar: Calendar) {
        let store = EKEventStore()
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date { AppTests.at(calendar, y, m, d, h, min) }
        func parts(_ y: Int, _ m: Int, _ d: Int, _ h: Int? = nil, _ min: Int = 0, zone: TimeZone? = nil) -> DateComponents {
            var value = DateComponents()
            value.calendar = calendar
            value.year = y
            value.month = m
            value.day = d
            if let h {
                value.hour = h
                value.minute = min
                value.second = 0
            }
            value.timeZone = zone
            return value
        }
        func reminder(due: DateComponents?, start: DateComponents? = nil, alarms: [EKAlarm] = []) -> EKReminder {
            let item = EKReminder(eventStore: store)
            item.title = "in-memory test reminder"
            item.dueDateComponents = due
            item.startDateComponents = start
            for alarm in alarms { item.addAlarm(alarm) }
            return item
        }
        func due(_ item: EKReminder) -> DueValue? { DueValue(components: item.dueDateComponents, calendar: calendar) }
        func start(_ item: EKReminder) -> DueValue? { DueValue(components: item.startDateComponents, calendar: calendar) }
        func clock(_ item: EKReminder) -> [Date] { (item.alarms ?? []).compactMap(\.absoluteDate).sorted() }
        func relative(_ item: EKReminder) -> [TimeInterval] {
            (item.alarms ?? []).filter { $0.absoluteDate == nil }.map(\.relativeOffset)
        }

        // Timed: the alarm at the due time follows; a relative and an unrelated alarm stay; an earlier start stays.
        let timed = reminder(due: parts(2026, 10, 1, 15), start: parts(2026, 10, 1, 9),
                             alarms: [EKAlarm(absoluteDate: at(2026, 10, 1, 15)), EKAlarm(relativeOffset: -600),
                                      EKAlarm(absoluteDate: at(2026, 9, 30, 20))])
        let timedRecord = moveDue(of: timed, to: DueValue(Day(2026, 10, 3), TimeOfDay(15, 0)), calendar: calendar)
        check.equal(due(timed), DueValue(Day(2026, 10, 3), TimeOfDay(15, 0)), "timed moved")
        check.equal(timed.dueDateComponents?.timeZone, nil, "stays floating like Reminders' own")
        check.equal(clock(timed), [at(2026, 9, 30, 20), at(2026, 10, 3, 15)], "due alarm followed, other kept")
        check.equal(relative(timed), [-600], "relative alarm kept")
        check.equal(start(timed), DueValue(Day(2026, 10, 1), TimeOfDay(9, 0)), "earlier start kept")
        restoreDue(of: timed, from: timedRecord)
        check.equal(due(timed), DueValue(Day(2026, 10, 1), TimeOfDay(15, 0)), "undo restores due")
        check.equal(clock(timed), [at(2026, 9, 30, 20), at(2026, 10, 1, 15)], "undo restores alarms")
        check.equal(relative(timed), [-600], "undo keeps relative alarm")

        // A start that would fall after the new due is pulled to it; no due alarm means none is invented.
        let inverted = reminder(due: parts(2026, 10, 5, 15), start: parts(2026, 10, 4, 9))
        _ = moveDue(of: inverted, to: DueValue(Day(2026, 10, 2), TimeOfDay(8, 0)), calendar: calendar)
        check.equal(start(inverted), DueValue(Day(2026, 10, 2), TimeOfDay(8, 0)), "start pulled to new due")
        check.equal(clock(inverted), [], "no alarm invented for a timed reminder without one")

        // All-day with the 00:00 start Reminders writes: the start follows and keeps 00:00.
        let allDay = reminder(due: parts(2026, 10, 1), start: parts(2026, 10, 1, 0))
        let allDayRecord = moveDue(of: allDay, to: DueValue(Day(2026, 10, 9)), calendar: calendar)
        check.equal(due(allDay), DueValue(Day(2026, 10, 9)), "all-day moved")
        check.equal(allDay.dueDateComponents?.hour, nil, "all-day stays date-only")
        check.equal(allDay.startDateComponents?.day, 9, "mirrored start followed")
        check.equal(allDay.startDateComponents?.hour, 0, "start kept its 00:00 shape")
        check.equal(clock(allDay), [], "all-day gets no alarm")
        restoreDue(of: allDay, from: allDayRecord)
        check.equal(allDay.startDateComponents?.day, 1, "undo restores start")
        check.equal(due(allDay), DueValue(Day(2026, 10, 1)), "undo restores all-day due")

        // Giving a time adds the alarm Reminders would add; making it all-day again removes it.
        let upgraded = reminder(due: parts(2026, 10, 1))
        _ = moveDue(of: upgraded, to: DueValue(Day(2026, 10, 1), TimeOfDay(18, 30)), calendar: calendar)
        check.equal(clock(upgraded), [at(2026, 10, 1, 18, 30)], "time adds its alarm")
        check.equal(upgraded.dueDateComponents?.hour, 18)
        _ = moveDue(of: upgraded, to: DueValue(Day(2026, 10, 1)), calendar: calendar)
        check.equal(clock(upgraded), [], "all-day removes the due alarm")
        check.equal(upgraded.dueDateComponents?.hour, nil)

        // Removing the date removes the due alarm and the start, and undo brings both back.
        let cleared = reminder(due: parts(2026, 10, 1, 15), start: parts(2026, 10, 1, 15),
                               alarms: [EKAlarm(absoluteDate: at(2026, 10, 1, 15)), EKAlarm(absoluteDate: at(2026, 9, 29, 9))])
        let clearedRecord = moveDue(of: cleared, to: nil, calendar: calendar)
        check.expect(cleared.dueDateComponents == nil, "due removed")
        check.expect(cleared.startDateComponents == nil, "start removed")
        check.equal(clock(cleared), [at(2026, 9, 29, 9)], "only the due alarm removed")
        restoreDue(of: cleared, from: clearedRecord)
        check.equal(due(cleared), DueValue(Day(2026, 10, 1), TimeOfDay(15, 0)))
        check.equal(start(cleared), DueValue(Day(2026, 10, 1), TimeOfDay(15, 0)))
        check.equal(clock(cleared), [at(2026, 9, 29, 9), at(2026, 10, 1, 15)])

        // A due pinned to another zone is read in local time and re-pinned to the local zone.
        let pinned = reminder(due: parts(2026, 10, 1, 6, zone: TimeZone(identifier: "UTC")),
                              alarms: [EKAlarm(absoluteDate: at(2026, 10, 1, 15))])
        check.equal(due(pinned), DueValue(Day(2026, 10, 1), TimeOfDay(15, 0)), "06:00 UTC read as 15:00")
        _ = moveDue(of: pinned, to: DueValue(Day(2026, 10, 2), TimeOfDay(15, 0)), calendar: calendar)
        check.equal(pinned.dueDateComponents?.timeZone, calendar.timeZone, "re-pinned to local zone")
        check.equal(pinned.dueDateComponents?.hour, 15)
        check.equal(clock(pinned), [at(2026, 10, 2, 15)], "pinned due alarm followed")

        // Undated to timed (also the quick-add path). Current EventKit fills an
        // empty start with the due date itself (older releases may not); either
        // way undo must take both back exactly.
        let fresh = reminder(due: nil)
        let freshRecord = moveDue(of: fresh, to: DueValue(Day(2026, 10, 1), TimeOfDay(15, 0)), calendar: calendar)
        check.equal(due(fresh), DueValue(Day(2026, 10, 1), TimeOfDay(15, 0)))
        check.equal(clock(fresh), [at(2026, 10, 1, 15)])
        check.expect(start(fresh) == nil || start(fresh) == DueValue(Day(2026, 10, 1), TimeOfDay(15, 0)),
                     "start is empty or EventKit's own default, got \(String(describing: start(fresh)))")
        restoreDue(of: fresh, from: freshRecord)
        check.expect(fresh.dueDateComponents == nil, "undo removes the due again")
        check.expect(fresh.startDateComponents == nil, "undo removes EventKit's start too")
        check.equal(clock(fresh), [], "undo removes the added alarm")

        // Clearing then undoing a reminder whose start was already empty keeps it empty.
        let noStart = reminder(due: parts(2026, 10, 1))
        noStart.startDateComponents = nil
        let noStartRecord = moveDue(of: noStart, to: nil, calendar: calendar)
        restoreDue(of: noStart, from: noStartRecord)
        check.equal(due(noStart), DueValue(Day(2026, 10, 1)))
        check.expect(noStart.startDateComponents == nil, "undo does not leave EventKit's auto start behind")
    }

    @MainActor
    static func modelTests(_ check: Checker, _ calendar: Calendar) async {
        let now = at(calendar, 2026, 9, 30, 18)
        let backend = DemoBackend(now: now, calendar: calendar)
        let model = AppModel(backend: backend, now: { now }, tickClock: false)
        func item(_ id: String) -> ReminderItem? { model.items.first { $0.id == id } }
        func d(_ m: Int, _ day: Int) -> Day { Day(2026, m, day) }

        await model.start()
        check.equal(model.access, .granted)
        check.equal(model.items.count, 11)
        check.equal(model.sections.map(\.bucket), [.overdue, .today, .tomorrow, .thisWeek, .later, .undated])
        check.equal(model.sections.first { $0.bucket == .today }?.items.map(\.id), ["r-library", "r-quiz"],
                    "all-day before timed")
        check.equal(model.count(for: .today), 3, "today includes overdue")
        check.equal(model.count(for: .overdue), 1)
        check.equal(model.count(for: .undated), 3)
        check.equal(model.count(for: .scheduled), 8)
        check.equal(model.count(for: .list("school")), 4)
        check.equal(model.dueCounts[d(10, 1)], 1)

        // Several reminders to tomorrow: each keeps its own time.
        model.selection = ["r-quiz", "r-library"]
        model.apply(.tomorrow)
        check.equal(item("r-quiz")?.due, DueValue(d(10, 1), TimeOfDay(21, 0)))
        check.equal(item("r-library")?.due, DueValue(d(10, 1)))
        check.equal(model.status?.tone, .success)
        check.equal(model.status?.text, "2개 → 내일 · 10월 1일 (목)")
        check.expect(model.canUndo, "undo offered")
        model.undoLast()
        check.equal(item("r-quiz")?.due, DueValue(d(9, 30), TimeOfDay(21, 0)), "undo restores quiz")
        check.equal(item("r-library")?.due, DueValue(d(9, 30)), "undo restores library")
        check.equal(backend.items.first { $0.id == "r-library" }?.due, DueValue(d(9, 30)), "undo reached the store")
        check.expect(!model.canUndo, "undo stack empty")
        await model.reload()

        // Postpone: from each reminder's own day, undated from today.
        model.selection = ["r-assignment", "r-backup"]
        model.apply(.postponeDay)
        check.equal(item("r-assignment")?.due, DueValue(d(9, 30)))
        check.equal(item("r-backup")?.due, DueValue(d(10, 1)))

        // A time alone keeps each day.
        model.selection = ["r-scholarship", "r-gym"]
        model.pick(time: TimeOfDay(9, 0))
        check.equal(item("r-scholarship")?.due, DueValue(d(10, 1), TimeOfDay(9, 0)))
        check.equal(item("r-gym")?.due, DueValue(d(10, 5), TimeOfDay(9, 0)))
        check.equal(model.sharedSelectedTime, .some(TimeOfDay(9, 0)), "shared time highlighted")
        model.pick(time: nil)
        check.equal(item("r-gym")?.due, DueValue(d(10, 5)), "종일")
        check.equal(model.sharedSelectedTime, .some(nil), "all-day shared")

        // Recurring cannot lose its date and read-only lists are left alone.
        model.selection = ["r-meeting", "r-dues", "r-trip"]
        model.apply(DuePreset.clear)
        check.equal(item("r-meeting")?.due, DueValue(d(10, 2), TimeOfDay(15, 0)), "recurring kept")
        check.equal(item("r-dues")?.due, DueValue(d(10, 3)), "read-only kept")
        check.equal(model.status?.tone, .warning)
        check.equal(model.sharedSelectedTime, nil, "mixed selection has no shared time")
        model.selection = ["r-meeting", "r-gym"]
        model.apply(DuePreset.clear)
        check.equal(item("r-gym")?.due, nil, "non-recurring cleared")
        check.equal(item("r-meeting")?.due, DueValue(d(10, 2), TimeOfDay(15, 0)))
        check.expect(model.status?.text.contains("반복 미리알림은 날짜를 없앨 수 없어요") == true,
                     "skip reason shown: \(model.status?.text ?? "nil")")
        check.expect(model.status?.offersUndo == true, "partial change still undoable")

        // Typed input.
        model.selection = ["r-study"]
        check.equal(model.displayedMonth, d(10, 1), "calendar follows the selection's month")
        model.dateInput = "다음 주 금 오후 3시"
        check.equal(model.dateInputPreview?.text, "↩︎ 10월 9일 (금) 오후 3:00")
        check.equal(model.dateInputPreview?.isError, false)
        model.submitDateInput()
        check.equal(item("r-study")?.due, DueValue(d(10, 9), TimeOfDay(15, 0)))
        check.equal(model.dateInput, "", "input cleared after applying")
        model.dateInput = "아무거나"
        check.equal(model.dateInputPreview?.isError, true)
        model.submitDateInput()
        check.equal(model.status?.tone, .error)
        check.equal(item("r-study")?.due, DueValue(d(10, 9), TimeOfDay(15, 0)), "bad input changes nothing")
        check.equal(model.dateInput, "아무거나", "bad input kept for fixing")
        model.dateInput = ""
        model.selection = ["r-quiz", "r-library"]
        model.dateInput = "+2"
        check.equal(model.dateInputPreview?.text, "↩︎ 2개 → 2일 미루기")
        model.dateInput = ""

        // Picking a calendar day keeps the time.
        model.selection = ["r-quiz"]
        model.pick(day: d(10, 12))
        check.equal(item("r-quiz")?.due, DueValue(d(10, 12), TimeOfDay(21, 0)))
        check.equal(model.status?.text, "‘운영체제 퀴즈 준비’ → 10월 12일 (월) 오후 9:00")

        // Nothing selected: nothing happens.
        model.selection = []
        model.apply(.today)
        check.equal(model.status?.tone, .warning)

        // Already there.
        model.selection = ["r-quiz"]
        model.pick(day: d(10, 12))
        check.equal(model.status?.tone, .info)

        // Changed somewhere else after the list was loaded.
        if let index = backend.items.firstIndex(where: { $0.id == "r-library" }) {
            backend.items[index].due = DueValue(d(10, 4))
        }
        model.selection = ["r-library"]
        model.apply(.nextMonday)
        check.equal(model.status?.tone, .warning)
        check.expect(model.status?.text.contains("다른 곳에서 먼저 바뀌어") == true, "conflict explained")
        check.equal(backend.items.first { $0.id == "r-library" }?.due, DueValue(d(10, 4)), "other change kept")
        await model.reload()
        check.equal(item("r-library")?.due, DueValue(d(10, 4)), "reload shows the other change")

        // A refused commit changes nothing.
        backend.failNextCommit = true
        model.apply(.today)
        check.equal(model.status?.tone, .error)
        check.equal(item("r-library")?.due, DueValue(d(10, 4)))
        check.equal(backend.items.first { $0.id == "r-library" }?.due, DueValue(d(10, 4)))

        // Quick add.
        model.filter = .list("club")
        check.equal(model.quickAddTargetListID, "todo", "read-only list is not a quick-add target")
        model.filter = .list("school")
        check.equal(model.quickAddTargetListID, "school", "filtered list is the default target")
        model.filter = .undated
        model.quickAddTitle = "택배 받기"
        model.quickAddDate = "내일 3시"
        check.equal(model.quickAddPreview?.text, "내일 · 10월 1일 (목) 오후 3:00")
        await model.performQuickAdd()
        let created = model.items.first { $0.title == "택배 받기" }
        check.equal(created?.due, DueValue(d(10, 1), TimeOfDay(15, 0)))
        check.equal(created?.listID, "todo")
        check.equal(model.selection, Set([created?.id ?? "missing"]), "new reminder selected")
        check.equal(model.filter, .all, "filter widened to show it")
        check.equal(model.quickAddTitle, "")
        let before = model.items.count
        model.quickAddTitle = "잘못된 날짜"
        model.quickAddDate = "아무거나"
        await model.performQuickAdd()
        check.equal(model.items.count, before, "nothing created for a bad date")
        check.equal(model.status?.tone, .error)
        model.quickAddDate = ""
        await model.performQuickAdd()
        check.equal(model.items.first { $0.title == "잘못된 날짜" }?.due, .some(nil), "no date is allowed")

        // Reminders already on the target day are counted, not silently dropped.
        model.selection = ["r-scholarship", "r-assignment"]
        model.apply(.tomorrow)
        check.equal(model.status?.text, "‘자료구조 과제 3 제출’ → 내일 · 10월 1일 (목) · 1개는 이미 그 날짜")
        check.equal(item("r-assignment")?.due, DueValue(d(10, 1)))

        // Search.
        model.search = "과제"
        check.equal(model.visibleItems.map(\.id), ["r-assignment"])
        model.search = ""

        // A reminder hidden by the search is not changed while it stays selected.
        model.filter = .all
        let unsubscribeBefore = item("r-unsubscribe")?.due
        model.selection = ["r-trip", "r-unsubscribe"]
        model.search = "여행"
        check.equal(model.selectedItems.map(\.id), ["r-trip"], "only the visible selection counts")
        model.apply(.tomorrow)
        check.equal(item("r-trip")?.due, DueValue(d(10, 1)))
        check.equal(item("r-unsubscribe")?.due, unsubscribeBefore, "hidden reminder untouched")
        check.equal(backend.items.first { $0.id == "r-unsubscribe" }?.due, unsubscribeBefore, "hidden reminder not saved")
        check.equal(model.status?.text, "‘겨울 여행 숙소 알아보기’ → 내일 · 10월 1일 (목)")
        model.search = "없는 제목"
        check.expect(!model.hasSelection, "nothing visible is selected")
        model.apply(.postponeDay)
        check.equal(model.status?.text, "고른 미리알림이 지금 목록에 보이지 않아요")
        check.equal(item("r-trip")?.due, DueValue(d(10, 1)), "a fully hidden selection changes nothing")
        model.search = ""
        check.equal(Set(model.selectedItems.map(\.id)), Set(["r-trip", "r-unsubscribe"]), "clearing the search brings both back")

        // A reminder that leaves the smart list after a change is no longer a target, until undo brings it back.
        model.selection = ["r-unsubscribe"]
        model.apply(.today)
        model.filter = .today
        check.equal(model.selectedItems.map(\.id), ["r-unsubscribe"])
        model.apply(.tomorrow)
        check.equal(item("r-unsubscribe")?.due, DueValue(d(10, 1)))
        check.expect(!model.hasSelection, "moved out of 오늘")
        model.apply(.postponeDay)
        check.equal(item("r-unsubscribe")?.due, DueValue(d(10, 1)), "not pushed again while hidden")
        model.undoLast()
        check.equal(item("r-unsubscribe")?.due, DueValue(d(9, 30)))
        check.equal(model.selectedItems.map(\.id), ["r-unsubscribe"], "back in 오늘 and still selected")
        model.filter = .all
    }

    // MARK: Management actions on DemoBackend

    @MainActor
    static func manageModelTests(_ check: Checker, _ calendar: Calendar) async {
        let now = at(calendar, 2026, 9, 30, 18)
        let backend = DemoBackend(now: now, calendar: calendar)
        let model = AppModel(backend: backend, now: { now }, tickClock: false)
        func item(_ id: String) -> ReminderItem? { model.items.first { $0.id == id } }
        func done(_ id: String) -> ReminderItem? { model.completedItems.first { $0.id == id } }
        await model.start()

        // Completed smart list loads.
        check.equal(model.count(for: .completed), 3, "완료됨 count")
        model.filter = .completed
        check.equal(model.isShowingCompleted, true)
        check.equal(Set(model.visibleItems.map(\.id)), Set(["c-report", "c-pay", "c-call"]), "completed visible")
        model.filter = .all

        // Complete a batch, with undo. Read-only and recurring are skipped/refused.
        model.selection = ["r-library", "r-gym"]
        model.setCompleted(true)
        check.equal(model.status?.tone, .success)
        check.expect(item("r-library") == nil && item("r-gym") == nil, "completed items left the active list")
        check.expect(done("r-library") != nil && done("r-gym") != nil, "completed items joined 완료됨")
        check.expect(model.canUndo, "complete offers undo")
        model.undoLast()
        check.expect(item("r-library") != nil, "undo restored to active list")
        await model.reload()

        // Recurring completion is refused, never silently dropped.
        model.selection = ["r-meeting"]
        model.setCompleted(true)
        check.equal(model.status?.tone, .warning)
        check.expect(model.status?.text.contains("반복 미리알림은 이 앱에서 완료할 수 없어요") == true,
                     "recurring completion refused: \(model.status?.text ?? "nil")")
        check.expect(item("r-meeting") != nil, "recurring reminder untouched")
        await model.reload()

        // Un-complete from the 완료됨 list.
        model.filter = .completed
        model.selection = ["c-call"]
        model.setCompleted(false)
        check.equal(model.status?.tone, .success)
        check.expect(backend.completed.first { $0.id == "c-call" } == nil, "un-completed left 완료됨")
        model.undoLast()
        model.filter = .all
        await model.reload()

        // Priority with undo; read-only skipped.
        model.selection = ["r-quiz"]
        model.setPriority(.high)
        check.equal(item("r-quiz")?.priority, .high, "priority set")
        check.equal(model.status?.tone, .success)
        model.undoLast()
        check.equal(item("r-quiz")?.priority, .medium, "priority restored")
        await model.reload()
        model.selection = ["r-dues"] // read-only list
        model.setPriority(.low)
        check.equal(model.status?.tone, .warning, "read-only priority skipped")
        check.expect(model.status?.text.contains("읽기 전용") == true, "read-only reason")

        // Move with undo; read-only destination not offered, source read-only skipped.
        model.selection = ["r-quiz"]
        model.move(toList: "personal")
        check.equal(item("r-quiz")?.listID, "personal", "moved")
        model.undoLast()
        check.equal(item("r-quiz")?.listID, "school", "move undone")
        await model.reload()

        // Edit title/notes of a single reminder with undo; empty title refused.
        model.selection = ["r-quiz"]
        model.loadEditDraft()
        model.editTitleDraft = "   "
        model.saveEdit()
        check.equal(model.status?.tone, .warning, "empty title refused")
        model.editTitleDraft = "운영체제 기말 준비"
        model.editNotesDraft = "5~8장 집중"
        model.saveEdit()
        check.equal(item("r-quiz")?.title, "운영체제 기말 준비", "title edited")
        check.equal(item("r-quiz")?.notes, "5~8장 집중", "notes edited")
        check.equal(model.status?.tone, .success)
        model.undoLast()
        check.equal(item("r-quiz")?.title, "운영체제 퀴즈 준비", "title restored")
        check.equal(item("r-quiz")?.notes, "", "notes restored")
        await model.reload()

        // Editing requires a single selection.
        model.selection = ["r-quiz", "r-library"]
        model.loadEditDraft()
        check.expect(model.singleSelected == nil, "no single selection for edit")

        // Delete confirmation flow: request opens the dialog; confirm deletes; no undo.
        model.selection = ["r-trip", "r-backup"]
        model.requestDelete()
        check.equal(model.pendingDelete?.count, 2, "delete dialog states the count")
        let undoDepthBefore = model.canUndo
        model.confirmDelete()
        check.equal(model.status?.tone, .success)
        check.expect(model.status?.text.contains("되돌릴 수 없음") == true, "delete states it cannot be undone")
        check.expect(backend.items.first { $0.id == "r-trip" } == nil, "r-trip deleted")
        check.expect(backend.items.first { $0.id == "r-backup" } == nil, "r-backup deleted")
        check.equal(model.canUndo, undoDepthBefore, "delete adds no undo entry")
        check.expect(model.pendingDelete == nil, "dialog closed")

        // Cancel delete changes nothing.
        model.selection = ["r-study"]
        model.requestDelete()
        model.cancelDelete()
        check.expect(model.pendingDelete == nil, "cancel closed the dialog")
        check.expect(backend.items.first { $0.id == "r-study" } != nil, "cancelled delete kept the item")

        // Stale guard: a field changed after load is left alone.
        if let index = backend.items.firstIndex(where: { $0.id == "r-study" }) {
            backend.items[index].title = "다른 곳에서 바뀐 제목"
        }
        model.selection = ["r-study"]
        model.setPriority(.high)
        check.equal(model.status?.tone, .warning, "stale item skipped")
        check.expect(model.status?.text.contains("다른 곳에서 먼저 바뀌어") == true, "stale reason")
        check.equal(backend.items.first { $0.id == "r-study" }?.priority, ReminderPriority.none, "stale item unchanged")
        await model.reload()

        // A refused commit changes nothing.
        backend.failNextCommit = true
        model.selection = ["r-scholarship"]
        model.setPriority(.high)
        check.equal(model.status?.tone, .error, "refused commit reported")
        check.equal(item("r-scholarship")?.priority, ReminderPriority.none, "refused commit changed nothing")
    }

    // MARK: Management edits on unsaved EventKit objects (never saved)

    @MainActor
    static func manageEventKitTests(_ check: Checker, _ calendar: Calendar) {
        let store = EKEventStore()
        func reminder(_ title: String) -> EKReminder {
            let r = EKReminder(eventStore: store)
            r.title = title
            return r
        }

        // Title and notes edit + restore; date fields untouched.
        let fields = reminder("원본 제목")
        fields.dueDateComponents = DateComponents(year: 2026, month: 10, day: 1)
        let fieldsRecord = applyFields(to: fields, title: "새 제목", notes: "새 메모")
        check.equal(fields.title, "새 제목", "title applied")
        check.equal(fields.notes, "새 메모", "notes applied")
        check.equal(fields.dueDateComponents?.day, 1, "date untouched by field edit")
        restoreFields(of: fields, from: fieldsRecord)
        check.equal(fields.title, "원본 제목", "title restored")
        check.expect(fields.notes == nil, "notes restored to empty")

        // Empty notes clears to nil, not an empty string.
        let clearNotes = reminder("t"); clearNotes.notes = "something"
        _ = applyFields(to: clearNotes, title: "t", notes: "")
        check.expect(clearNotes.notes == nil, "empty notes clears to nil")

        // Priority mapping: set + restore; a value inside a bucket is not rewritten.
        let prio = reminder("p"); prio.priority = 0
        let prioRecord = applyPriority(to: prio, .high)
        check.equal(prio.priority, 1, "high writes EventKit 1")
        restorePriority(of: prio, from: prioRecord)
        check.equal(prio.priority, 0, "priority restored")
        let inBucket = reminder("p2"); inBucket.priority = 2 // already 'high' bucket
        _ = applyPriority(to: inBucket, .high)
        check.equal(inBucket.priority, 2, "value inside the same bucket is left as-is")
        check.equal(ReminderPriority.fromEventKit(2), .high, "2 reads as high")
        check.equal(ReminderPriority.fromEventKit(5), .medium, "5 reads as medium")
        check.equal(ReminderPriority.fromEventKit(9), .low, "9 reads as low")
        check.equal(ReminderPriority.fromEventKit(0), ReminderPriority.none, "0 reads as none")

        // Completion flag + restore; completion date set then cleared.
        let comp = reminder("c")
        let when = at(calendar, 2026, 9, 30, 12)
        let compRecord = applyCompletion(to: comp, complete: true, now: when)
        check.equal(comp.isCompleted, true, "marked complete")
        check.equal(comp.completionDate, when, "completion date set")
        restoreCompletion(of: comp, from: compRecord)
        check.equal(comp.isCompleted, false, "completion restored")
        check.expect(comp.completionDate == nil, "completion date cleared on restore")

        // Move planning: calendar reassignment is a plain property set (no store write).
        let mv = reminder("m")
        let before = mv.calendar
        // We cannot create a real EKCalendar without a source here, so only
        // assert the in-memory assignment contract: setting then clearing.
        mv.calendar = before
        check.expect(mv.calendar === before, "calendar assignment is in-memory")
    }

    // MARK: Login-agent self-heal (injected directory)

    @MainActor
    static func loginAgentTests(_ check: Checker) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agents-" + UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        let label = "com.icloud-reminders-google-sync.due-picker.login"
        let oldExe = "/Users/x/Applications/미리알림 날짜.app/Contents/MacOS/DuePicker"
        let newExe = "/Applications/Reminders Due Picker.app/Contents/MacOS/DuePicker"

        // Absent: self-heal never creates it.
        check.equal(LoginAgent.needsSelfHeal(label: label, agentsDirectory: dir, executablePath: newExe), false,
                    "absent agent does not need self-heal")
        check.expect((try? LoginAgent.selfHeal(label: label, agentsDirectory: dir, executablePath: newExe)) == false,
                     "self-heal did not create an absent agent")
        check.expect(!fm.fileExists(atPath: LoginAgent.path(label: label, agentsDirectory: dir).path),
                     "no plist created when absent")

        // Present but stale: self-heal rewrites ProgramArguments[0] and keeps the rest.
        do { try LoginAgent.write(label: label, agentsDirectory: dir, executablePath: oldExe) }
        catch { check.expect(false, "write failed: \(error)") }
        check.equal(LoginAgent.currentExecutable(label: label, agentsDirectory: dir), oldExe, "wrote old exe")
        check.equal(LoginAgent.needsSelfHeal(label: label, agentsDirectory: dir, executablePath: newExe), true,
                    "stale agent needs self-heal")
        check.expect((try? LoginAgent.selfHeal(label: label, agentsDirectory: dir, executablePath: newExe)) == true,
                     "self-heal rewrote the stale agent")
        check.equal(LoginAgent.currentExecutable(label: label, agentsDirectory: dir), newExe, "exe updated")
        let path = LoginAgent.path(label: label, agentsDirectory: dir).path
        check.equal(try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600, "mode 0600")
        if let data = try? Data(contentsOf: LoginAgent.path(label: label, agentsDirectory: dir)),
           let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            check.equal(dict["Label"] as? String, label, "Label kept")
            check.equal(dict["RunAtLoad"] as? Bool, true, "RunAtLoad kept")
            check.equal(dict["ProcessType"] as? String, "Interactive", "ProcessType kept")
            // The WHOLE array must be exactly [newExe, --background] — not merely
            // ending in --background — so a partial rewrite that appended to the
            // old array would fail here.
            check.equal(dict["ProgramArguments"] as? [String] ?? [], [newExe, "--background"],
                        "ProgramArguments is exactly [newExe, --background]")
            check.equal(Set(dict.keys), Set(["Label", "ProgramArguments", "RunAtLoad", "ProcessType"]),
                        "key set is exactly the canonical four")
        } else {
            check.expect(false, "could not read rewritten plist")
        }

        // Already current: self-heal is a no-op.
        check.equal(LoginAgent.needsSelfHeal(label: label, agentsDirectory: dir, executablePath: newExe), false,
                    "current agent needs no self-heal")
        check.expect((try? LoginAgent.selfHeal(label: label, agentsDirectory: dir, executablePath: newExe)) == false,
                     "self-heal was a no-op on a current agent")
    }

    // MARK: Notion mirror status parsing (injected path)

    @MainActor
    static func notionStatusTests(_ check: Checker) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("notion-" + UUID().uuidString)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notion-mirror-state.json")

        // Missing file → neutral unavailable, never an error.
        check.equal(NotionMirrorStatus.read(from: file), .unknown, "missing file is unavailable")

        // Valid file → reads only the three fields.
        let json = """
        {"lastSuccessAt":"2026-10-22T09:00:00Z","pendingCreates":2,"counts":{"total":184,"other":1},"secret":"ignored"}
        """
        try? Data(json.utf8).write(to: file)
        let status = NotionMirrorStatus.read(from: file)
        check.equal(status.unavailable, false, "readable file is available")
        check.equal(status.pendingCreates, 2, "pendingCreates read")
        check.equal(status.total, 184, "counts.total read")
        check.expect(status.lastSuccessAt != nil, "lastSuccessAt parsed")

        // Unreadable JSON → neutral unavailable.
        try? Data("not json".utf8).write(to: file)
        check.equal(NotionMirrorStatus.read(from: file), .unknown, "garbage is unavailable")

        // Partial object → zeros, still available.
        let partial = NotionMirrorStatus.parse(["pendingCreates": 0])
        check.equal(partial.total, 0, "missing counts.total defaults to 0")
        check.equal(partial.unavailable, false, "partial but present is available")
    }
}
