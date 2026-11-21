import CoreDomain
import XCTest
@testable import RoomInTheCart

final class PantryVoiceParserTests: XCTestCase {
    func testReadOnlyBalanceWithTrailingPlaceKeepsFoodAndStorageWithoutAUseIntent() {
        for (text, target, locale) in [
            ("¿Cuánto ajonjolí me queda en el refrigerador?", "ajonjolí en el refrigerador", "es_MX"),
            ("How much sesame do I have left in the fridge?", "sesame in the fridge", "en_US"),
            ("How much sesame in the cupboard is left?", "sesame in the cupboard", "en_US"),
            ("¿Cuántas manzanas nos quedan en la alacena?", "manzanas en la alacena", "es_MX")
        ] {
            XCTAssertEqual(PantryVoiceParser.parse(text, localeIdentifier: locale), .balanceQuery(target))
        }
        for text in ["How much sesame in the fridge is left in the freezer?",
                     "¿Cuánto ajonjolí me queda en el refrigerador? Añade sal",
                     "How much sesame do I have left in the car?"] {
            XCTAssertEqual(PantryVoiceParser.parse(text, localeIdentifier: "en_US"), .needsReview(text))
        }
    }

    func testReadOnlyBalanceQuestionsAndLocationQualifiedUnmeasuredUses() throws {
        XCTAssertEqual(PantryVoiceParser.parse("¿Cuánto ajonjolí me queda?", localeIdentifier: "es_MX"), .balanceQuery("ajonjolí"))
        XCTAssertEqual(PantryVoiceParser.parse("How much sesame do I have left?", localeIdentifier: "en_US"), .balanceQuery("sesame"))
        for (command, food, locale) in [
            ("Usé un poco de ajonjolí del refrigerador", "ajonjolí del refrigerador", "es_MX"),
            ("I used some sesame from the fridge", "sesame from the fridge", "en_US")
        ] {
            guard case .consume(let items) = PantryVoiceParser.parse(command, localeIdentifier: locale) else {
                return XCTFail(command)
            }
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.food, food)
            XCTAssertEqual(items.first?.amount, .someUsed)
        }
        let unsupported = "How much rice do I have left? add beans"
        XCTAssertEqual(PantryVoiceParser.parse(unsupported, localeIdentifier: "en_US"), .needsReview(unsupported))
    }

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

    func testSingleUnmeasuredUseKeepsItsRoughRemainderAndOriginalSource() {
        for (locale, wording, food, remainder) in [
            ("es-MX", "Usé arroz integral, creo que queda un poco.", "arroz integral", "creo que queda un poco"),
            ("en-US", "I used brown rice, I think there’s a little left.", "brown rice", "I think there’s a little left"),
            ("en-US", "I just used some brown rice and I have some left", "brown rice", "I have some left"),
            ("es-MX", "Acabo de usar un poco de arroz integral me queda algo", "arroz integral", "me queda algo")
        ] {
            let estimate = PantryVoiceObservation(food: food, original: wording, remaining: .some, remainingWording: remainder)
            let item = PantryVoiceItem(original: wording, food: food, amount: .someUsedWithRemaining(estimate))
            XCTAssertEqual(PantryVoiceParser.parse(wording, localeIdentifier: locale), .consume([item]), wording)
            XCTAssertNil(PantryVoiceParser.parseRemainingReply(wording, localeIdentifier: locale), wording)
        }
    }

    func testRoughRemainderCannotGuessWhetherOrHowMuchOfWhichFoodWasUsed() {
        for (locale, text) in [
            ("es-MX", "No usé arroz integral, creo que queda un poco."),
            ("es-MX", "Creo que usé arroz integral, queda un poco."),
            ("es-MX", "Usé arroz y frijoles, creo que queda un poco."),
            ("es-MX", "Usé dos tazas de arroz, creo que queda un poco."),
            ("es-MX", "Usé arroz, creo que queda un poco de harina."),
            ("es-MX", "Usé arroz, creo que está vacío."),
            ("en-US", "I think I used brown rice, there's a little left."),
            ("en-US", "I never used brown rice, there's a little left."),
            ("en-US", "I used rice and flour, I think there’s a little left."),
            ("en-US", "I used two cups of rice, there's a little left."),
            ("en-US", "I used all the rice, there's a little left."),
            ("en-US", "I used rice, there's some flour left."),
            ("en-US", "I used rice, I think it's empty."),
            ("en-US", "I used rice, I think there's a little left?"),
            ("en-US", "I used rice, I think there's a little left, then add milk.")
        ] {
            XCTAssertEqual(PantryVoiceParser.parse(text, localeIdentifier: locale), .needsReview(text), text)
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

    func testSpokenFullnessPreservesDifferentFoodsContainersQualifiersAndWording() throws {
        let half = try Rational(1, 2)
        let examples: [(String, String, String, PantryVoiceRemaining, String)] = [
            ("en-US", "My rice bag is still kind of full", "rice", .somewhatFull, "still kind of full"),
            ("en-US", "I've got more than half a jar of salsa left", "salsa", .moreThanFraction(half, container: "jar"), "more than half a jar left"),
            ("en-US", "The oat milk is half full", "oat milk", .fraction(half, container: nil), "half full"),
            ("en-US", "My oat milk is more than half full", "oat milk", .moreThanFraction(half, container: nil), "more than half full"),
            ("en-US", "The flour is almost gone", "flour", .nearlyEmpty, "almost gone"),
            ("en-US", "The tub of rice and beans is mostly full", "rice and beans", .mostlyFull, "mostly full"),
            ("en-US", "My bag of rice has less than half left", "rice", .lessThanFraction(half, container: nil), "less than half left"),
            ("en-US", "The homemade sauce is full", "homemade sauce", .full, "full"),
            ("en-US", "The homemade sauce is nearly full", "homemade sauce", .nearlyFull, "nearly full"),
            ("es-US", "Mi bolsa de arroz todavía está bastante llena", "arroz", .somewhatFull, "todavía está bastante llena"),
            ("es-US", "Mi leche de avena está a más de la mitad", "leche de avena", .moreThanFraction(half, container: nil), "a más de la mitad"),
            ("es-US", "Me queda más de la mitad del frasco de salsa casera", "salsa casera", .moreThanFraction(half, container: "frasco"), "más de la mitad del frasco"),
            ("es-US", "A mi frasco de salsa le queda menos de la mitad", "salsa", .lessThanFraction(half, container: nil), "menos de la mitad"),
            ("es-US", "El envase de arroz y frijoles está casi lleno", "arroz y frijoles", .nearlyFull, "casi lleno")
        ]
        for (locale, source, food, value, wording) in examples {
            XCTAssertEqual(PantryVoiceParser.parse(source, localeIdentifier: locale),
                           .observation(.init(food: food, original: source, remaining: value, remainingWording: wording)), source)
        }
    }

    func testOnlyARemainingPromptCanResolveABareFractionAndCannotSwitchTheNamedBatch() throws {
        let half = try Rational(1, 2)
        for (locale, source, result) in [
            ("en-US", "half", PantryVoiceRemaining.fraction(half, container: nil)),
            ("es-US", "la mitad", .fraction(half, container: nil)),
            ("en-US", "less than half", .lessThanFraction(half, container: nil)),
            ("es-US", "más de la mitad", .moreThanFraction(half, container: nil))
        ] {
            XCTAssertEqual(PantryVoiceParser.parse(source, localeIdentifier: locale), .needsReview(source))
            XCTAssertEqual(PantryVoiceParser.parseRemainingReply(source, localeIdentifier: locale),
                           .init(food: "", original: source, remaining: result, remainingWording: source))
        }
        for (locale, source, result) in [
            ("en-US", "more than half left", PantryVoiceRemaining.moreThanFraction(half, container: nil)),
            ("en-US", "almost empty", .nearlyEmpty), ("en-US", "still kind of full", .somewhatFull),
            ("en-US", "mostly full", .mostlyFull), ("es-US", "casi vacía", .nearlyEmpty),
            ("es-US", "todavía bastante llena", .somewhatFull)
        ] {
            let reply = PantryVoiceObservation(food: "", original: source, remaining: result, remainingWording: source)
            XCTAssertEqual(PantryVoiceParser.parse(source, localeIdentifier: locale), .observation(reply))
            XCTAssertEqual(PantryVoiceParser.parseRemainingReply(source, localeIdentifier: locale), reply)
        }
        for source in ["I used half", "Usé la mitad"] {
            XCTAssertEqual(parse(source), .askRemaining(food: nil, original: source))
        }
        for source in ["half of the mayonnaise", "I used half", "I have half a jar of salsa left",
                       "my beans are mostly full", "half or almost empty", "not half", "half?", "buy milk"] {
            XCTAssertNil(PantryVoiceParser.parseRemainingReply(source, localeIdentifier: "en-US"), source)
        }
    }

    func testMealSizedEstimateAndOutOfStockNeverAssertConsumption() {
        let examples: [(String, String, PantryVoiceRemaining, String)] = [
            ("My homemade soup has enough for one more meal", "homemade soup", .enoughForMeal, "enough for one more meal"),
            ("There's enough rice for one more dinner", "rice", .enoughForMeal, "enough for one more dinner"),
            ("Hay suficiente salsa casera para una comida más", "salsa casera", .enoughForMeal, "suficiente para una comida más"),
            ("Mi sopa casera alcanza para una porción más", "sopa casera", .enoughForMeal, "alcanza para una porción más"),
            ("We're out of milk", "milk", .empty, "We're out of"),
            ("Se nos acabó la leche", "leche", .empty, "Se nos acabó")
        ]
        for (source, food, value, wording) in examples {
            XCTAssertEqual(parse(source), .observation(.init(food: food, original: source, remaining: value, remainingWording: wording)))
        }
        for source in ["enough for one more serving", "suficiente para una cena más"] {
            XCTAssertEqual(PantryVoiceParser.parseRemainingReply(source, localeIdentifier: "es-US"),
                           .init(food: "", original: source, remaining: .enoughForMeal, remainingWording: source))
        }
        for source in ["We're not out of milk", "No se nos acabó la leche", "Buy milk", "Buy milk, we're out of milk",
                       "The flour is nearly empty but the jar is full", "We are out of milk and buy rice"] {
            XCTAssertEqual(parse(source), .needsReview(source), source)
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
