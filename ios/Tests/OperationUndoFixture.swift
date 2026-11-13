import Foundation
import HouseholdClient

/// Fixed synthetic complete-operation fixture, no inverse reducer or real-service claim.
enum OperationUndoFixture {
    static let json = #"""
{
  "context": {
    "subject": "fixture-subject",
    "householdID": "00000000-0000-4000-8000-000000000001",
    "memberID": "00000000-0000-4000-8000-000000000009",
    "deviceID": "00000000-0000-4000-8000-000000000010"
  },
  "page": {
    "schemaVersion": 1,
    "shopId": "00000000-0000-4000-8000-000000000002",
    "shopRevision": 7,
    "authorityEpoch": 2,
    "status": "enabled",
    "graphDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "graph": {
      "schemaVersion": 1,
      "conversionTableVersion": "us-customary-metric-v1",
      "householdId": "00000000-0000-4000-8000-000000000001",
      "shopId": "00000000-0000-4000-8000-000000000002",
      "revision": 3,
      "lines": [
        {
          "id": "00000000-0000-4000-8000-000000000003",
          "name": "Wraps",
          "unit": "count",
          "originalOrder": 0,
          "trashedAt": null
        }
      ],
      "contributions": [
        {
          "id": "00000000-0000-4000-8000-000000000004",
          "lineId": "00000000-0000-4000-8000-000000000003",
          "source": {
            "kind": "manual"
          },
          "productKey": "wraps",
          "productName": "Wraps",
          "originalText": "Original source wording",
          "quantity": {
            "amount": {
              "numerator": "8",
              "denominator": "1"
            },
            "unit": "count",
            "originalLiteral": "Eight original wraps",
            "confirmedConversion": null
          },
          "exclusions": [],
          "contains": [],
          "removedAt": null
        }
      ],
      "edges": [],
      "usedIds": [
        "00000000-0000-4000-8000-000000000003",
        "00000000-0000-4000-8000-000000000004"
      ]
    },
    "totals": [
      {
        "lineId": "00000000-0000-4000-8000-000000000003",
        "unit": "count",
        "quantity": {
          "numerator": "8",
          "denominator": "1"
        },
        "activeContributionIds": [
          "00000000-0000-4000-8000-000000000004"
        ]
      }
    ]
  },
  "shop": {
    "shopId": "00000000-0000-4000-8000-000000000002",
    "shopRevision": 7,
    "authorityEpoch": 2,
    "phase": "draft",
    "quote": {
      "currency": "USD",
      "scope": "wholeCheckout",
      "complete": true,
      "capMinor": 1000,
      "capScope": "wholeCheckout",
      "fee": {
        "kind": "fixed",
        "amountMinor": 0
      },
      "taxesMinor": 0,
      "depositsMinor": 0,
      "discountsMinor": 0,
      "observedAt": "2026-11-09T12:00:00Z",
      "expiresAt": "2099-11-09T13:00:00Z"
    },
    "lines": [
      {
        "lineId": "00000000-0000-4000-8000-000000000003",
        "originalItem": "Original wraps",
        "packs": 3,
        "unitPriceMinor": 200,
        "feeEligible": true
      }
    ],
    "meals": [],
    "frozenRevision": null,
    "placedRevision": null
  },
  "target": {
    "operationId": "00000000-0000-4000-8000-000000000006",
    "kind": "shop.patch",
    "shopRevision": 5,
    "committedAt": "2026-11-09T12:05:00Z",
    "eligibility": {
      "status": "reviewable",
      "reason": "explicit_current_preview_required"
    }
  },
  "history": {
    "schemaVersion": 1,
    "shopId": "00000000-0000-4000-8000-000000000002",
    "shopRevision": 7,
    "authorityEpoch": 2,
    "items": [
      {
        "operationId": "00000000-0000-4000-8000-000000000006",
        "kind": "shop.patch",
        "shopRevision": 5,
        "committedAt": "2026-11-09T12:05:00Z",
        "eligibility": {
          "status": "reviewable",
          "reason": "explicit_current_preview_required"
        }
      }
    ],
    "nextBeforeRevision": null
  },
  "candidate": {
    "schemaVersion": 1,
    "shopId": "00000000-0000-4000-8000-000000000002",
    "base": {
      "shopRevision": 7,
      "authorityEpoch": 2,
      "graphRevision": 3,
      "graphDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "targetOperationId": "00000000-0000-4000-8000-000000000006",
    "effectDigest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "scope": {
      "targetOperationId": "00000000-0000-4000-8000-000000000006",
      "baseShopRevision": 4,
      "resultShopRevision": 5,
      "touchedLines": [
        {
          "lineId": "00000000-0000-4000-8000-000000000003",
          "fields": [
            "packs"
          ]
        }
      ],
      "quoteChanged": false,
      "graphRows": 0,
      "mealsChanged": false,
      "requestsChanged": false
    },
    "action": {
      "kind": "shop.patch",
      "body": {
        "lines": [
          {
            "lineId": "00000000-0000-4000-8000-000000000003",
            "originalItem": "Original wraps",
            "packs": 2,
            "unitPriceMinor": 200,
            "feeEligible": true
          }
        ],
        "quote": {
          "currency": "USD",
          "scope": "wholeCheckout",
          "complete": true,
          "capMinor": 1000,
          "capScope": "wholeCheckout",
          "fee": {
            "kind": "fixed",
            "amountMinor": 0
          },
          "taxesMinor": 0,
          "depositsMinor": 0,
          "discountsMinor": 0,
          "observedAt": "2026-11-09T12:00:00Z",
          "expiresAt": "2099-11-09T13:00:00Z"
        }
      }
    },
    "before": {
      "schemaVersion": 1,
      "conversionTableVersion": "us-customary-metric-v1",
      "householdId": "00000000-0000-4000-8000-000000000001",
      "shopId": "00000000-0000-4000-8000-000000000002",
      "revision": 3,
      "lines": [
        {
          "id": "00000000-0000-4000-8000-000000000003",
          "name": "Wraps",
          "unit": "count",
          "originalOrder": 0,
          "trashedAt": null
        }
      ],
      "contributions": [
        {
          "id": "00000000-0000-4000-8000-000000000004",
          "lineId": "00000000-0000-4000-8000-000000000003",
          "source": {
            "kind": "manual"
          },
          "productKey": "wraps",
          "productName": "Wraps",
          "originalText": "Original source wording",
          "quantity": {
            "amount": {
              "numerator": "8",
              "denominator": "1"
            },
            "unit": "count",
            "originalLiteral": "Eight original wraps",
            "confirmedConversion": null
          },
          "exclusions": [],
          "contains": [],
          "removedAt": null
        }
      ],
      "edges": [],
      "usedIds": [
        "00000000-0000-4000-8000-000000000003",
        "00000000-0000-4000-8000-000000000004"
      ]
    },
    "after": {
      "schemaVersion": 1,
      "conversionTableVersion": "us-customary-metric-v1",
      "householdId": "00000000-0000-4000-8000-000000000001",
      "shopId": "00000000-0000-4000-8000-000000000002",
      "revision": 4,
      "lines": [
        {
          "id": "00000000-0000-4000-8000-000000000003",
          "name": "Wraps",
          "unit": "count",
          "originalOrder": 0,
          "trashedAt": null
        }
      ],
      "contributions": [
        {
          "id": "00000000-0000-4000-8000-000000000004",
          "lineId": "00000000-0000-4000-8000-000000000003",
          "source": {
            "kind": "manual"
          },
          "productKey": "wraps",
          "productName": "Wraps",
          "originalText": "Original source wording",
          "quantity": {
            "amount": {
              "numerator": "8",
              "denominator": "1"
            },
            "unit": "count",
            "originalLiteral": "Eight original wraps",
            "confirmedConversion": null
          },
          "exclusions": [],
          "contains": [],
          "removedAt": null
        }
      ],
      "edges": [],
      "usedIds": [
        "00000000-0000-4000-8000-000000000003",
        "00000000-0000-4000-8000-000000000004"
      ]
    },
    "beforeTotals": [
      {
        "lineId": "00000000-0000-4000-8000-000000000003",
        "unit": "count",
        "quantity": {
          "numerator": "8",
          "denominator": "1"
        },
        "activeContributionIds": [
          "00000000-0000-4000-8000-000000000004"
        ]
      }
    ],
    "afterTotals": [
      {
        "lineId": "00000000-0000-4000-8000-000000000003",
        "unit": "count",
        "quantity": {
          "numerator": "8",
          "denominator": "1"
        },
        "activeContributionIds": [
          "00000000-0000-4000-8000-000000000004"
        ]
      }
    ],
    "beforeCheckout": {
      "currency": "USD",
      "totalMinor": 600,
      "overCapMinor": 0,
      "headroomMinor": 400,
      "status": "withinCap",
      "scope": "wholeCheckout",
      "missing": [],
      "lowerBoundMinor": 600,
      "upperBoundMinor": 600,
      "wholeCheckoutWithinCap": true
    },
    "afterCheckout": {
      "currency": "USD",
      "totalMinor": 400,
      "overCapMinor": 0,
      "headroomMinor": 600,
      "status": "withinCap",
      "scope": "wholeCheckout",
      "missing": [],
      "lowerBoundMinor": 400,
      "upperBoundMinor": 400,
      "wholeCheckoutWithinCap": true
    },
    "packReviewLineIds": [
      "00000000-0000-4000-8000-000000000003"
    ]
  },
  "packs": [
    {
      "lineId": "00000000-0000-4000-8000-000000000003",
      "usablePerPack": {
        "amount": {
          "numerator": "4",
          "denominator": "1"
        },
        "unit": "count",
        "originalLiteral": "Four per pack",
        "confirmedConversion": null
      },
      "acceptUnresolved": false
    }
  ],
  "response": {
    "previewId": "00000000-0000-4000-8000-000000000007",
    "previewDigest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "expiresAt": "2099-11-09T12:10:00Z",
    "before": {
      "schemaVersion": 1,
      "conversionTableVersion": "us-customary-metric-v1",
      "householdId": "00000000-0000-4000-8000-000000000001",
      "shopId": "00000000-0000-4000-8000-000000000002",
      "revision": 3,
      "lines": [
        {
          "id": "00000000-0000-4000-8000-000000000003",
          "name": "Wraps",
          "unit": "count",
          "originalOrder": 0,
          "trashedAt": null
        }
      ],
      "contributions": [
        {
          "id": "00000000-0000-4000-8000-000000000004",
          "lineId": "00000000-0000-4000-8000-000000000003",
          "source": {
            "kind": "manual"
          },
          "productKey": "wraps",
          "productName": "Wraps",
          "originalText": "Original source wording",
          "quantity": {
            "amount": {
              "numerator": "8",
              "denominator": "1"
            },
            "unit": "count",
            "originalLiteral": "Eight original wraps",
            "confirmedConversion": null
          },
          "exclusions": [],
          "contains": [],
          "removedAt": null
        }
      ],
      "edges": [],
      "usedIds": [
        "00000000-0000-4000-8000-000000000003",
        "00000000-0000-4000-8000-000000000004"
      ]
    },
    "after": {
      "schemaVersion": 1,
      "conversionTableVersion": "us-customary-metric-v1",
      "householdId": "00000000-0000-4000-8000-000000000001",
      "shopId": "00000000-0000-4000-8000-000000000002",
      "revision": 4,
      "lines": [
        {
          "id": "00000000-0000-4000-8000-000000000003",
          "name": "Wraps",
          "unit": "count",
          "originalOrder": 0,
          "trashedAt": null
        }
      ],
      "contributions": [
        {
          "id": "00000000-0000-4000-8000-000000000004",
          "lineId": "00000000-0000-4000-8000-000000000003",
          "source": {
            "kind": "manual"
          },
          "productKey": "wraps",
          "productName": "Wraps",
          "originalText": "Original source wording",
          "quantity": {
            "amount": {
              "numerator": "8",
              "denominator": "1"
            },
            "unit": "count",
            "originalLiteral": "Eight original wraps",
            "confirmedConversion": null
          },
          "exclusions": [],
          "contains": [],
          "removedAt": null
        }
      ],
      "edges": [],
      "usedIds": [
        "00000000-0000-4000-8000-000000000003",
        "00000000-0000-4000-8000-000000000004"
      ]
    },
    "receipt": {
      "schemaVersion": 1,
      "operationId": "00000000-0000-4000-8000-000000000008",
      "householdId": "00000000-0000-4000-8000-000000000001",
      "shopId": "00000000-0000-4000-8000-000000000002",
      "baseRevision": 3,
      "resultRevision": 4,
      "lines": [],
      "contributions": [],
      "edges": []
    },
    "packs": [
      {
        "lineId": "00000000-0000-4000-8000-000000000003",
        "usablePerPack": {
          "amount": {
            "numerator": "4",
            "denominator": "1"
          },
          "unit": "count",
          "originalLiteral": "Four per pack",
          "confirmedConversion": null
        },
        "acceptUnresolved": false
      }
    ],
    "beforeTotals": [
      {
        "lineId": "00000000-0000-4000-8000-000000000003",
        "unit": "count",
        "quantity": {
          "numerator": "8",
          "denominator": "1"
        },
        "activeContributionIds": [
          "00000000-0000-4000-8000-000000000004"
        ]
      }
    ],
    "afterTotals": [
      {
        "lineId": "00000000-0000-4000-8000-000000000003",
        "unit": "count",
        "quantity": {
          "numerator": "8",
          "denominator": "1"
        },
        "activeContributionIds": [
          "00000000-0000-4000-8000-000000000004"
        ]
      }
    ],
    "shopRevision": 7,
    "authorityEpoch": 2,
    "operationUndo": {
      "targetOperationId": "00000000-0000-4000-8000-000000000006",
      "effectDigest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "scope": {
        "targetOperationId": "00000000-0000-4000-8000-000000000006",
        "baseShopRevision": 4,
        "resultShopRevision": 5,
        "touchedLines": [
          {
            "lineId": "00000000-0000-4000-8000-000000000003",
            "fields": [
              "packs"
            ]
          }
        ],
        "quoteChanged": false,
        "graphRows": 0,
        "mealsChanged": false,
        "requestsChanged": false
      }
    },
    "action": {
      "kind": "shop.patch",
      "body": {
        "lines": [
          {
            "lineId": "00000000-0000-4000-8000-000000000003",
            "originalItem": "Original wraps",
            "packs": 2,
            "unitPriceMinor": 200,
            "feeEligible": true
          }
        ],
        "quote": {
          "currency": "USD",
          "scope": "wholeCheckout",
          "complete": true,
          "capMinor": 1000,
          "capScope": "wholeCheckout",
          "fee": {
            "kind": "fixed",
            "amountMinor": 0
          },
          "taxesMinor": 0,
          "depositsMinor": 0,
          "discountsMinor": 0,
          "observedAt": "2026-11-09T12:00:00Z",
          "expiresAt": "2099-11-09T13:00:00Z"
        }
      }
    },
    "beforeCheckout": {
      "currency": "USD",
      "totalMinor": 600,
      "overCapMinor": 0,
      "headroomMinor": 400,
      "status": "withinCap",
      "scope": "wholeCheckout",
      "missing": [],
      "lowerBoundMinor": 600,
      "upperBoundMinor": 600,
      "wholeCheckoutWithinCap": true
    },
    "afterCheckout": {
      "currency": "USD",
      "totalMinor": 400,
      "overCapMinor": 0,
      "headroomMinor": 600,
      "status": "withinCap",
      "scope": "wholeCheckout",
      "missing": [],
      "lowerBoundMinor": 400,
      "upperBoundMinor": 400,
      "wholeCheckoutWithinCap": true
    }
  }
}
"""#
    /// Fixed response facts for a skipped dinner, distinct protected lunch and a
    /// later staple. This never computes a server inverse from arbitrary input.
    static func mealObject() throws -> [String: Any] {
        var f = try object()
        let occurrence = "00000000-0000-4000-8000-000000000041", ingredient = "00000000-0000-4000-8000-000000000042"
        let lunch = "00000000-0000-4000-8000-000000000051", lunchIngredient = "00000000-0000-4000-8000-000000000052"
        let mealSource = "00000000-0000-4000-8000-000000000021", protectedSource = "00000000-0000-4000-8000-000000000022"
        let wraps = "00000000-0000-4000-8000-000000000003", apples = "00000000-0000-4000-8000-000000000011", appleSource = "00000000-0000-4000-8000-000000000012"
        func amount(_ value: String) -> [String: Any] { ["numerator": value, "denominator": "1"] }
        func quantity(_ value: String, _ literal: String) -> [String: Any] {
            ["amount": amount(value), "unit": "count", "originalLiteral": literal, "confirmedConversion": NSNull()]
        }
        let meal: [String: Any] = ["title": "Original taco dinner", "day": "2026-11-10", "kind": "dinner", "portions": 3, "protected": false,
            "planning": ["groups": [], "ingredients": [["id": ingredient, "name": "Taco wraps",
                "quantity": ["amount": ["numerator": 6, "denominator": 1], "unit": "count", "originalLiteral": "Six original taco wraps"], "groupIds": [], "exclusions": []]]]]
        let lunchMeal: [String: Any] = ["title": "Protected lunch", "day": NSNull(), "kind": "lunch", "portions": 2, "protected": true,
            "planning": ["groups": [], "ingredients": [["id": lunchIngredient, "name": "Lunch wraps",
                "quantity": ["amount": ["numerator": 2, "denominator": 1], "unit": "count", "originalLiteral": "Two lunch wraps"], "groupIds": [], "exclusions": []]]]]
        var page = f["page"] as! [String: Any], shop = f["shop"] as! [String: Any]
        var before = page["graph"] as! [String: Any]
        let firstLine = (before["lines"] as! [[String: Any]])[0]
        let appleLine: [String: Any] = ["id": apples, "name": "Later apples", "unit": "count", "originalOrder": 1, "trashedAt": NSNull()]
        var manual = (before["contributions"] as! [[String: Any]])[0]
        manual["quantity"] = quantity("2", "Two wraps for breakfast"); manual["originalText"] = "Two manual wraps"
        var protected = manual; protected["id"] = protectedSource; protected["originalText"] = "Two wraps held for lunch"
        protected["quantity"] = quantity("2", "Two lunch wraps")
        protected["source"] = ["kind": "reservation", "reservationId": "00000000-0000-4000-8000-000000000053", "purpose": "Protected lunch",
            "originOccurrenceId": lunch, "ingredientId": lunchIngredient, "groupId": NSNull(), "bindingId": NSNull()] as [String: Any]
        var skipped = manual; skipped["id"] = mealSource; skipped["originalText"] = "Six original taco wraps"
        skipped["quantity"] = quantity("6", "Six original taco wraps"); skipped["removedAt"] = "2026-11-09T12:05:00Z"
        skipped["source"] = ["kind": "meal", "occurrenceId": occurrence, "ingredientId": ingredient, "groupId": NSNull(), "bindingId": NSNull()] as [String: Any]
        var restored = skipped; restored["removedAt"] = NSNull()
        var later = manual; later["id"] = appleSource; later["lineId"] = apples; later["productKey"] = "apples"
        later["productName"] = "Later apples"; later["originalText"] = "Later apples — amount unknown"; later["quantity"] = NSNull()
        before["lines"] = [firstLine, appleLine]; before["contributions"] = [manual, protected, skipped, later]
        before["usedIds"] = [wraps, manual["id"]!, protectedSource, mealSource, apples, appleSource]
        var after = before; after["revision"] = 4; after["contributions"] = [manual, protected, restored, later]
        func totals(_ value: String, _ ids: [Any]) -> [[String: Any]] {
            [["lineId": wraps, "unit": "count", "quantity": amount(value), "activeContributionIds": ids],
             ["lineId": apples, "unit": "count", "quantity": NSNull(), "activeContributionIds": [appleSource]]]
        }
        let beforeTotals = totals("4", [manual["id"]!, protectedSource]), afterTotals = totals("10", [manual["id"]!, protectedSource, mealSource])
        page["graph"] = before; page["totals"] = beforeTotals; f["page"] = page
        let initial: [[String: Any]] = [["lineId": wraps, "originalItem": "Wraps", "packs": 1, "unitPriceMinor": 200, "feeEligible": true],
            ["lineId": apples, "originalItem": "Later apples", "packs": 1, "unitPriceMinor": 300, "feeEligible": true]]
        var final = initial; final[0]["packs"] = 2
        shop["lines"] = initial; shop["meals"] = [["occurrenceId": lunch, "revision": 4, "meal": lunchMeal]]; f["shop"] = shop
        let evidence: [String: Any] = ["occurrenceId": occurrence, "targetBefore": ["revision": 4, "meal": meal],
            "targetAfter": ["revision": 5, "meal": NSNull()], "current": ["revision": 5, "meal": NSNull()],
            "restoredMeal": meal, "touchedFields": ["membership"], "proposal": NSNull()]
        let action: [String: Any] = ["kind": "shop.patch", "body": ["quote": shop["quote"]!, "lines": final,
            "mealEdit": ["occurrenceId": occurrence, "baseMealRevision": NSNull(), "meal": meal]]]
        var candidate = f["candidate"] as! [String: Any], response = f["response"] as! [String: Any]
        var scope = candidate["scope"] as! [String: Any]; scope["mealsChanged"] = true; scope["graphRows"] = 1
        scope["touchedLines"] = [["lineId": wraps, "fields": ["packs"]]]
        var beforeBudget = candidate["beforeCheckout"] as! [String: Any], afterBudget = beforeBudget
        for key in ["totalMinor", "lowerBoundMinor", "upperBoundMinor"] { beforeBudget[key] = 500; afterBudget[key] = 700 }
        beforeBudget["headroomMinor"] = 500; afterBudget["headroomMinor"] = 300
        candidate["scope"] = scope; candidate["mealUndo"] = evidence; candidate["packReviewLineIds"] = [wraps, apples]
        let values: [String: Any] = ["action": action, "before": before, "after": after, "beforeTotals": beforeTotals, "afterTotals": afterTotals,
            "beforeCheckout": beforeBudget, "afterCheckout": afterBudget]
        for (key, value) in values { candidate[key] = value; response[key] = value }
        let packs: [[String: Any]] = [["lineId": wraps, "usablePerPack": quantity("8", "8"), "acceptUnresolved": false],
            ["lineId": apples, "usablePerPack": NSNull(), "acceptUnresolved": true]]
        response["mealUndo"] = evidence; response["packs"] = packs
        var metadata = response["operationUndo"] as! [String: Any]; metadata["scope"] = scope; response["operationUndo"] = metadata
        var receipt = response["receipt"] as! [String: Any]
        receipt["lines"] = []; receipt["edges"] = []; receipt["contributions"] = [["id": mealSource, "before": skipped, "after": restored]]
        response["receipt"] = receipt; f["candidate"] = candidate; f["response"] = response; f["packs"] = packs
        var history = f["history"] as! [String: Any]; history["items"] = [f["target"]!]; f["history"] = history
        return f
    }

    static func object() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any] }
    static func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static func value<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T { try decode(object()[key]!, as: type) }
    static func review(_ object: [String: Any]? = nil) throws -> SharedOperationUndoReview {
        let f = try object ?? self.object()
        let candidate: SharedOperationUndoCandidate = try decode(f["candidate"]!)
        let packs: [SharedDemandPackReview] = try decode(f["packs"]!)
        return try .init(context: decode(f["context"]!), page: decode(f["page"]!), shop: decode(f["shop"]!), target: decode(f["target"]!),
            candidate: candidate, request: .init(candidate: candidate, packs: packs), response: decode(f["response"]!))
    }
}
