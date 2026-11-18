import CoreDomain
import XCTest
@testable import RoomInTheCart

final class PantryVoiceParserTests: XCTestCase {
    func testNaturalEnglishAndSpanishConsumptionKeepEachQuantityAndPieceWording() throws {
        for (locale, command, names, rows, piece) in [
            ("en-US", "hey I just used two eggs and two pieces of bread and some flour",
             ["eggs", "bread", "flour"], ["two eggs", "two pieces of bread", "some flour"], "pieces"),
            ("es-US", "Oye, acabo de usar dos huevos y dos rebanadas de pan y un poco de harina",
             ["huevos", "pan", "harina"], ["dos huevos", "dos rebanadas de pan", "un poco de harina"], "rebanadas")
        ] {
            guard case .consume(let items) = PantryVoiceParser.parse(command, localeIdentifier: locale) else {
                return XCTFail(command)
            }
            let two = try Rational(2)
            XCTAssertEqual(items.map(\.food), names)
            XCTAssertEqual(items.map(\.original), rows)
            XCTAssertEqual(items.map(\.amount), [.measured(Quantity(amount: two, unit: .count, originalLiteral: rows[0])),
                                                 .pieces(two, piece), .someUsed])
        }
    }

    func testPoliteFridgeUpdateAfterConsumptionKeepsEveryIngredientAndRejectsOtherQuestions() {
        let english = "Hey, I just used two eggs and two pieces of bread and some flour"
        let spanish = "Oye, acabo de usar dos huevos y dos rebanadas de pan y un poco de harina"
        for (language, command, endings) in [
            ("en-US", english, [". Can you update my fridge?", ", can you please update my pantry?", " can you update my fridge?"]),
            ("es-US", spanish, [". ¿Puedes actualizar mi despensa?", ", ¿puedes actualizar mi refrigerador?", " puedes actualizar mi despensa"])
        ] {
            let expected = PantryVoiceParser.parse(command, localeIdentifier: language)
            guard case .consume(let items) = expected, items.count == 3 else { return XCTFail(command) }
            for ending in endings {
                XCTAssertEqual(PantryVoiceParser.parse(command + ending, localeIdentifier: language), expected)
            }
        }
        for text in [english + ". Can you add milk as well?", english + "? Can you update my fridge?",
                     spanish + ". ¿Puedes borrar el pan?", "I used two eggs, add milk. Can you update my fridge?",
                     "Usé dos huevos, compré pan. ¿Puedes actualizar mi despensa?", "I did not use two eggs. Can you update my fridge?",
                     "I used two eggs, but don't update anything. Can you update my fridge?",
                     "Is my ketchup expired? Can you update my fridge?"] {
            XCTAssertEqual(parse(text), .needsReview(text), text)
        }
    }

    func testOnlyExplicitUsedAllOffersToFinishNamedFood() {
        for (source, food) in [("delete the bread I used it all", "bread"), ("Borra el pan, lo usé todo", "pan"),
                               ("I used all of the rice and beans", "rice and beans")] {
            XCTAssertEqual(parse(source), .consume([PantryVoiceItem(original: source, food: food, amount: .all)]))
        }
        for source in ["delete bread", "Borra el pan", "I used all but two eggs", "I used all the eggs and bread"] {
            XCTAssertEqual(parse(source), .needsReview(source))
        }
    }

    func testDateQuestionsAreReadOnlyIncludingSpanishWordOrder() {
        for (source, food) in [("Is my ketchup expired?", "ketchup"), ("When does my Kimchi expire?", "Kimchi"),
                               ("¿Está vencida mi salsa de tomate?", "salsa de tomate"), ("¿Mi kétchup está vencido?", "kétchup")] {
            XCTAssertEqual(parse(source), .dateQuery(food))
        }
        for source in ["Is my ketchup expired? I used two eggs", "I used two eggs?", "¿Usé dos huevos?",
                       "I used two eggs that expired", "¿Está vencida mi salsa y usé dos huevos?"] {
            XCTAssertEqual(parse(source), .needsReview(source))
        }
    }

    func testQualitativeRemainingRetainsQualifierAndNeverBecomesAnAmountUsed() throws {
        let half = try Rational(1, 2)
        let cases: [(String, String, PantryVoiceRemaining, String)] = [
            ("I'm running low on ketchup, I have less than half a bottle left", "ketchup", .lessThanFraction(half, container: "bottle"), "less than half a bottle left"),
            ("I'm running low on ketchup I have less than half a bottle left", "ketchup", .lessThanFraction(half, container: "bottle"), "less than half a bottle left"),
            ("Me queda poco kétchup, me queda menos de media botella", "kétchup", .lessThanFraction(half, container: "botella"), "menos de media botella"),
            ("I'm running low on mustard", "mustard", .low, "running low"),
            ("I have some flour left", "flour", .some, "some left"),
            ("Me queda un poco de harina", "harina", .some, "un poco"),
            ("I have some left", "", .some, "some left"),
            ("Me queda algo", "", .some, "algo"),
            ("the bottle is nearly empty", "", .nearlyEmpty, "nearly empty"),
            ("está casi vacía", "", .nearlyEmpty, "casi vacía"),
            ("the bottle of ketchup is nearly empty", "ketchup", .nearlyEmpty, "nearly empty"),
            ("la botella de kétchup está vacía", "kétchup", .empty, "vacía"),
            ("I have half a bottle of ketchup left", "ketchup", .fraction(half, container: "bottle"), "half a bottle left"),
            ("I have under half a jar of jam left", "jam", .lessThanFraction(half, container: "jar"), "under half a jar left"),
            ("Me queda como media botella de kétchup", "kétchup", .aboutFraction(half, container: "botella"), "como media botella"),
            ("I have about half a bottle of ketchup left", "ketchup", .aboutFraction(half, container: "bottle"), "about half a bottle left"),
            ("there is about half left", "", .aboutFraction(half, container: nil), "about half left"),
            ("queda como la mitad", "", .aboutFraction(half, container: nil), "como la mitad")
        ]
        for (source, food, remaining, wording) in cases {
            XCTAssertEqual(parse(source), .observation(PantryVoiceObservation(food: food, original: source,
                remaining: remaining, remainingWording: wording)), source)
        }
    }

    func testApproximateFractionUsedAsksWhatRemainsAndKeepsOriginalWords() {
        let cases: [(String, String?)] = [
            ("I used like half the bottle of ketchup", "ketchup"),
            ("Usé como la mitad de la botella de kétchup", "kétchup"),
            ("I used about half the bottle", nil), ("Usé como la mitad de la botella", nil)
        ]
        for (source, food) in cases {
            XCTAssertEqual(parse(source), .askRemaining(food: food, original: source))
        }
        XCTAssertEqual(parse("some flour used"), .consume([PantryVoiceItem(original: "some flour", food: "flour", amount: .someUsed)]))
    }

    func testExplicitSomeUsedCanBeLoggedWithNoQuantityAndSomeLeftIsReadOnly() {
        for (source, wording, food) in [("I used some ketchup", "some ketchup", "ketchup"),
                                         ("Usé un poco de kétchup", "un poco de kétchup", "kétchup")] {
            XCTAssertEqual(parse(source), .consume([PantryVoiceItem(original: wording, food: food, amount: .someUsed)]))
        }
        XCTAssertEqual(parse("I used flour"), .consume([PantryVoiceItem(original: "flour", food: "flour", amount: .unknown)]))
        for (source, food) in [("I have some ketchup left", "ketchup"), ("Me queda un poco de kétchup", "kétchup")] {
            guard case .observation(let observation) = parse(source) else { return XCTFail(source) }
            XCTAssertEqual(observation.food, food)
            XCTAssertEqual(observation.remaining, .some)
        }
    }

    func testMixedMeasuresAndCompoundFoodNamesRetainMeaning() throws {
        for (source, wording, food, value, unit) in [
            ("I used a cup and a half of flour", "a cup and a half of flour", "flour", try Rational(3, 2), UnitOfMeasure.cup),
            ("Usé 0,5 kg de arroz", "0,5 kg de arroz", "arroz", try Rational(1, 2), .kilogram),
            ("I used 100 g of mac and cheese", "100 g of mac and cheese", "mac and cheese", try Rational(100), .gram)
        ] {
            XCTAssertEqual(parse(source), .consume([PantryVoiceItem(original: wording, food: food,
                amount: .measured(Quantity(amount: value, unit: unit, originalLiteral: wording)))]))
        }
    }

    func testConflictsUnsupportedWordingAndUnknownPackageMeasuresKeepOriginalForReview() {
        for source in ["I used two or three eggs", "Usé dos o tres huevos", "I used 1–2 cups of flour",
                       "I used six scoops of flour", "I used two handfuls of rice", "I used two bottles of syrup",
                       "I used a few eggs", "I used a couple eggs", "I used 2,000 g of rice", "I used 2 eggs and 3 eggs", "I used two eggs yesterday",
                       "I did not use two eggs", "If I used two eggs", "I used two eggs and I have one left", "I used two eggs for breakfast",
                       "I have some ketchup and mustard left", "Me queda poco kétchup y mostaza",
                       "I'm running low on ketchup, I have less than half a bottle of mustard left", "not sure"] {
            XCTAssertEqual(parse(source), .needsReview(source), source)
        }
        XCTAssertEqual(PantryVoiceParser.parse("I used two eggs", localeIdentifier: "fr"), .needsReview("I used two eggs"))
    }

    private func parse(_ command: String) -> PantryVoiceIntent {
        PantryVoiceParser.parse(command, localeIdentifier: "es-US")
    }
}
