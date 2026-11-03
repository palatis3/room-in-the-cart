import CoreDomain
import Foundation

enum DinnerPatternCatalog {
    // Published pattern and ingredient identities survive relaunch and language changes.
    private static func id(_ pattern: UInt8, _ ingredient: UInt8 = 0) -> UUID {
        UUID(uuid: (0x60,0xfa,0xd3,0x24,0xed,0xb2,0x47,0x2a,0xb3,0x87,0x82,0x90,0x51,0xd6,pattern,ingredient))
    }

    static let patterns: [MealTemplate] = {
        func food(_ pattern: UInt8, _ index: UInt8, _ name: String, _ amount: Rational, _ unit: UnitOfMeasure) -> MealIngredient {
            MealIngredient(id: id(pattern,index), name: name,
                quantity: Quantity(amount: amount, unit: unit, originalLiteral: amount.description))
        }
        // Fixed, positive whole quantities in the bundled patterns.
        let two = try! Rational(2), four = try! Rational(4)
        let half = try! Rational(1,2), six = try! Rational(6)
        return [
            MealTemplate(id: id(1), title: dinnerText("Rice bowls with beans and corn"), servings: two,
                ingredients: [food(1,1,dinnerText("Cooked rice"),two,.cup),
                              food(1,2,dinnerText("Cooked beans"),.one,.cup),
                              food(1,3,dinnerText("Corn kernels"),half,.cup)],
                notes: dinnerText("Warm the rice, beans and corn, then divide between two bowls. The estimate assumes cooked rice and beans. Add any toppings to the list yourself."),
                leadTimeMinutes: 15),
            MealTemplate(id: id(2), title: dinnerText("Tomato pasta with peas"), servings: two,
                ingredients: [food(2,1,dinnerText("Dry short pasta"),six,.ounce),
                              food(2,2,dinnerText("Tomato sauce"),.one,.cup),
                              food(2,3,dinnerText("Peas"),half,.cup)],
                notes: dinnerText("Cook the pasta according to its package. Warm the sauce and peas, then combine. The estimate assumes water and a stovetop are available."),
                leadTimeMinutes: 25),
            MealTemplate(id: id(3), title: dinnerText("Bean and cabbage wraps"), servings: two,
                ingredients: [food(3,1,dinnerText("Tortillas"),four,.count),
                              food(3,2,dinnerText("Cooked beans"),.one,.cup),
                              food(3,3,dinnerText("Shredded cabbage"),.one,.cup)],
                notes: dinnerText("Divide the beans and cabbage between four tortillas. The estimate assumes cooked beans and shredded cabbage. List any sauce separately."),
                leadTimeMinutes: 15)
        ]
    }()
}
