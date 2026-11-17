import XCTest
@testable import CoreDomain

final class NaturalListSegmenterTests: XCTestCase {
    func testSpokenListKeepsExactTranscriptRangesAndOneTimingPhrase() throws {
        let words = "Two milks, bread and cereal for next week."
        let proposal = try NaturalListSegmenter.propose(words)
        XCTAssertEqual(proposal.items.map { String($0.wording) }, ["Two milks", "bread", "cereal"])
        XCTAssertEqual(proposal.timing, "for next week")
        XCTAssertTrue(proposal.items.allSatisfy { !$0.needsBoundaryReview })
        XCTAssertEqual(words[proposal.items[2].wording.startIndex...], "cereal for next week.")
        let repeats = try NaturalListSegmenter.propose("pan, pan y leche para la próxima compra")
        XCTAssertEqual(repeats.items.map(\.wording), ["pan", "pan", "leche"])
        XCTAssertNotEqual(repeats.items[0].wording.startIndex, repeats.items[1].wording.startIndex)
        XCTAssertEqual(repeats.timing, "para la próxima compra")
    }

    func testKeepsQualifiersCompoundsQuotedNamesAndMeasuredFractionsTogether() throws {
        let cases: [(String, [Substring])] = [
            ("mac and cheese, eggs, and milk", ["mac and cheese", "eggs", "milk"]),
            ("bread and mac and cheese, milk", ["bread", "mac and cheese", "milk"]),
            ("2 cans of beans, 6 to 8 oz each, tea", ["2 cans of beans, 6 to 8 oz each", "tea"]),
            ("2 latas de frijoles, 15 onzas cada una, pan", ["2 latas de frijoles, 15 onzas cada una", "pan"]),
            ("2,5 litros de leche y pan", ["2,5 litros de leche", "pan"]),
            ("one and a half cups rice, eggs", ["one and a half cups rice", "eggs"]),
            ("arroz y frijoles y 2 huevos", ["arroz y frijoles", "2 huevos"]),
            ("tea without nuts, milk and soy; bread", ["tea without nuts, milk and soy", "bread"]),
            ("milk, no sugar and no soy", ["milk, no sugar and no soy"]),
            ("apples for Mia and Sam, dinner", ["apples for Mia and Sam, dinner"]),
            ("“milk, eggs and bread”, café (té y leche)", ["“milk, eggs and bread”", "café (té y leche)"])
        ]
        for (text, expected) in cases {
            XCTAssertEqual(try NaturalListSegmenter.propose(text).items.map(\.wording), expected, text)
        }
        let measured = try NaturalListSegmenter.propose("dos y media tazas de arroz y pan")
        XCTAssertEqual(measured.items.map(\.wording), ["dos y media tazas de arroz", "pan"])
        XCTAssertFalse(measured.items[0].needsBoundaryReview)
        let ranged = try NaturalListSegmenter.propose("two to three apples, milk")
        XCTAssertEqual(ranged.items.map(\.wording), ["two to three apples", "milk"])
        let unclear = try NaturalListSegmenter.propose("mango and sticky rice")
        XCTAssertEqual(unclear.items.map(\.wording), ["mango and sticky rice"])
        XCTAssertTrue(unclear.items[0].needsBoundaryReview)
        let mixed = try NaturalListSegmenter.propose("tea for this week and coffee for next week")
        XCTAssertNil(mixed.timing)
        XCTAssertTrue(mixed.requiresTimingReview)
        let prefix = try NaturalListSegmenter.propose("Para la próxima semana, pan y leche")
        XCTAssertFalse(prefix.requiresTimingReview)
        XCTAssertEqual(prefix.timing, "Para la próxima semana")
        XCTAssertEqual(prefix.items.map(\.wording), ["pan", "leche"])
        XCTAssertFalse(try NaturalListSegmenter.propose("tea, “cake for next week”").requiresTimingReview)
    }

    func testExpansionLimitCountsItemsInsideOneUtterance() throws {
        XCTAssertThrowsError(try NaturalListSegmenter.propose("tea, rice, eggs", maximumItems: 2)) {
            XCTAssertEqual($0 as? ImportTextLimit, .nonblankLines(maximum: 2))
        }
        XCTAssertTrue(try NaturalListSegmenter.propose("   \n ").items.isEmpty)
    }
}
