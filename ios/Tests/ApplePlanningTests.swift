import XCTest
import CoreDomain
@testable import RoomInTheCart
#if os(iOS)
import EventKit
#endif

final class ApplePlanningTests: XCTestCase {
    func testCopyUsesSelectedIncompleteTitlesInSourceOrderAndRetainsDraft() throws {
        let rows = [
            ReminderCopyRow(id: "m", title: " Milk ", completed: false),
            ReminderCopyRow(id: "b", title: "Beans", completed: true),
            ReminderCopyRow(id: "a", title: "Rice\n2 bags", completed: false),
            ReminderCopyRow(id: "c", title: "Apples", completed: false),
            ReminderCopyRow(id: "d", title: "  ", completed: false)
        ].compactMap { $0 }
        XCTAssertEqual(rows.map(\.id), ["m", "a", "c"])
        XCTAssertEqual(try ReminderCopyRow.selectedText(rows: rows, selected: ["a", "b", "m"], appendingTo: "Water"),
                       "Water\nMilk\nRice 2 bags")
        XCTAssertThrowsError(try ReminderCopyRow.selectedText(rows: rows, selected: ["b"], appendingTo: "Water"))
    }

    func testRepeatedCopySurfacesDuplicateForTheSelectedPickup() throws {
        let row = try XCTUnwrap(ReminderCopyRow(id: "opaque-source", title: "Milk", completed: false))
        var shop = ShoppingLedger(title: "Friday")
        let text = try ReminderCopyRow.selectedText(rows: [row], selected: [row.id], appendingTo: "")
        let first = try shop.stageImport(text: text, source: .selectedText)
        try shop.commitImport(first, decisions: [first.lines[0].id: .addNew])
        let repeatCopy = try shop.stageImport(text: text, source: .selectedText)
        XCTAssertEqual(repeatCopy.shopID, shop.id)
        XCTAssertEqual(repeatCopy.lines[0].duplicateLineIDs, [first.lines[0].proposedLineID])
        try shop.commitImport(repeatCopy, decisions: [repeatCopy.lines[0].id: .skip])
        XCTAssertEqual(shop.lines.count, 1)
    }

    func testPasteFallbackLetsShopperOmitRowsBeforeReview() throws {
        let rows = try ReminderCopyRow.pastedTitles(["Milk\r\nBread", "Rice"])
        XCTAssertEqual(rows.map(\.title), ["Milk", "Bread", "Rice"])
        let selected = Set(rows.filter { $0.title != "Bread" }.map(\.id))
        XCTAssertEqual(try ReminderCopyRow.selectedText(rows: rows, selected: selected, appendingTo: ""), "Milk\nRice")
    }

    func testCopyRejectsOverlongCombinedDraftBeforeStaging() throws {
        let row = try XCTUnwrap(ReminderCopyRow(id: "a", title: "Milk", completed: false))
        let draft = Array(repeating: "Water", count: StagedListImport.maximumLines).joined(separator: "\n")
        XCTAssertThrowsError(try ReminderCopyRow.selectedText(rows: [row], selected: ["a"], appendingTo: draft))
    }

    func testAllDayCopyTracksCivilDayAcrossDaylightSavingAndMealMoves() throws {
        let firstDay = try MealDay(year: 2026, month: 3, day: 8, timeZoneIdentifier: "America/New_York")
        let copy = try XCTUnwrap(DinnerCalendarDraft(day: firstDay, prepTime: nil, title: "Dinner"))
        XCTAssertTrue(copy.allDay)
        XCTAssertEqual(copy.end.timeIntervalSince(copy.start), 23 * 3600)
        let later = try MealDay(year: 2026, month: 3, day: 10, timeZoneIdentifier: firstDay.timeZoneIdentifier)
        let moved = try XCTUnwrap(DinnerCalendarDraft(day: later, prepTime: nil, title: "Dinner"))
        XCTAssertEqual(try MealDay(date: copy.start, timeZoneIdentifier: firstDay.timeZoneIdentifier), firstDay)
        XCTAssertNotEqual(copy.start, moved.start)
    }

    func testOptionalPrepTimeMustBelongToScheduledDay() throws {
        let day = try MealDay(year: 2026, month: 11, day: 1, timeZoneIdentifier: "America/Los_Angeles")
        let noon = try XCTUnwrap(day.date)
        let event = try XCTUnwrap(DinnerCalendarDraft(day: day, prepTime: noon, title: "Cena"))
        XCTAssertFalse(event.allDay)
        XCTAssertEqual(event.title, "Cena")
        XCTAssertEqual(event.start, noon)
        XCTAssertEqual(event.end.timeIntervalSince(noon), 1800)
        XCTAssertNil(DinnerCalendarDraft(day: day, prepTime: noon.addingTimeInterval(86400), title: "Cena"))
    }

    #if os(iOS)
    @MainActor func testDeniedRemindersAccessLeavesNoListsAndOffersPasteFallback() async throws {
        let reader = GroceryReminderReader(requestAccess: { _ in false })
        await reader.loadSources()
        XCTAssertFalse(reader.loading)
        XCTAssertTrue(reader.sources.isEmpty)
        XCTAssertTrue(reader.rows.isEmpty)
        XCTAssertTrue(reader.status.contains("paste"))
        XCTAssertEqual(try ReminderCopyRow.pastedTitles(["Rice"]).first?.title, "Rice")
    }

    @MainActor func testSystemEditorReceivesOnlyOneGenericUnsavedEvent() throws {
        let day = try MealDay(year: 2026, month: 11, day: 20, timeZoneIdentifier: "America/New_York")
        let draft = try XCTUnwrap(DinnerCalendarDraft(day: day, prepTime: nil, title: "Dinner"))
        let event = draft.makeEvent(store: EKEventStore())
        XCTAssertEqual(event.title, "Dinner")
        XCTAssertNil(event.notes)
        XCTAssertNil(event.location)
        XCTAssertNil(event.url)
        XCTAssertFalse(event.hasRecurrenceRules)
        XCTAssertFalse(event.hasAttendees)
    }
    #endif
}
