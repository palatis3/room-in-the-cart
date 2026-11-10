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
