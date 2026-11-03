# CoreDomain

Pure Swift 5.9 package for Foundation 2.1 B01 / D01 / D05 / F01. No network, UI, database, or third-party dependencies. Supports iOS 17 and macOS 13.

`ComparisonRequest` is the durable Codable input. Persist the request with an external record ID and date; recompute with `try PackComparison.evaluate(request)`. Every result is explicitly `itemOnly`. There is no household-budget result type.

```swift
let need = Quantity(amount: try Rational(12), unit: .count, originalLiteral: "12")
let eight = Quantity(amount: try Rational(8), unit: .count, originalLiteral: "8 wraps")
let six = Quantity(amount: try Rational(6), unit: .count, originalLiteral: "6 wraps")
let request = ComparisonRequest(
    itemName: "Wraps", needed: need,
    offerA: PackOffer(id: "a", label: "Eight wraps", usableQuantity: eight,
                      price: Money(minorUnits: 349)),
    offerB: PackOffer(id: "b", label: "Six wraps", usableQuantity: six,
                      price: Money(minorUnits: 299)),
    itemCap: Money(minorUnits: 600)
)
let result = try PackComparison.evaluate(request)
// A: 2 packs, $6.98, 4 left, -$0.98 item headroom.
// B: 2 packs, $5.98, 0 left,  $0.02 item headroom.
```

## Quantity and evidence semantics

- `needed` is the total accepted need, including `protectedAmount`. Protection partitions that total; it never adds another copy of the demand. Protection greater than need is invalid.
- `confirmedAtHome` means matched, confirmed usable stock available for this need. Reservations for other needs have already been removed. Nil counts no confirmed supply; it does not claim an empty pantry.
- `usableQuantity` describes **one package**. Nil means unknown yield. Zero means no usable food, leaving the need open.
- `price` describes **one package** in USD cents. Nil never becomes a free package. When existing stock covers the whole need, zero packages have zero purchase cost independently of the unknown package price.
- A missing need yields unresolved results. An explicit zero need is distinct.
- All rational output quantities use `ComparisonResult.unit`, the needed unit.
- Metric and US customary conversions are exact and versioned as `us-customary-metric-v1`. Weight and volume never convert implicitly. `UnitBasis` records an explicitly confirmed, ingredient-specific ratio. Store this evidence with the quantity or offer; never reuse it automatically for a different ingredient.
- `itemHeadroom` is signed. `unitCeiling` is item cap divided by required whole-pack count, rounded down to integer cents. Neither includes unrelated items, taxes, fees, or pickup costs.
- `preferredOfferID` only selects the lower known purchase total when both offers fully resolve. Nil represents ties or uncertainty. A preference does not claim any cap was met.

## Arithmetic and validation

`Rational` uses reduced, nonnegative Int64 numerators and positive Int64 denominators. Constructors and numeric decoding reject invalid signs/denominators. Arithmetic checks overflow; multiplication/division cancel common factors before multiplying, and comparison uses full-width integer products. Representational overflow throws `DomainError.overflow`, including intermediate overflow. Callers must show a correctable input error.

`Rational(decimal:)` accepts plain ASCII decimal input with at most 18 significant fractional places and 64 source bytes. `Money(decimal:)` rejects fractional cents instead of rounding. `approximateValue` is exclusively for display; decisions use integer/rational arithmetic. Money accepts signed Int64 cents for headroom and future adjustments; evaluation rejects negative package prices and item caps.

Evaluation bounds item/offer names to 512 UTF-8 bytes, offer IDs to 128, and quantity literals/conversion notes to 2,048. It rejects duplicate/empty offer IDs and invalid explicit bases. Data-loading layers should additionally bound JSON payload size before decoding. A literal is retained as evidence and is never reparsed by evaluation; the reviewed rational is authoritative.

## Verification

From the repository root, run `swift test --package-path ios/Packages/CoreDomain`. Tests consume `shared/contracts/pack-comparisons.json` and 2,000 deterministic randomized checks for conservation and minimal whole-pack counts. These checks establish the calculation contract, not device accessibility or the full B01 application gate.
