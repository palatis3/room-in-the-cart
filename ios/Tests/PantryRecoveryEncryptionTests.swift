import XCTest
import RecordArchive
@testable import RoomInTheCart

final class PantryRecoveryEncryptionTests: XCTestCase {
    func testRandomizedPartsRoundTripWithOneUserHeldKeyAndNoPlaintext() throws {
        let key = EncryptedArchive.generateKey(), context = PantryRecoveryEncryption.Context(bundleID: UUID(), name: "pantry-0.json")
        let original = Data("Private groceries and a reviewed receipt".utf8)
        let first = try PantryRecoveryEncryption.seal(original, context: context, key: key)
        let second = try PantryRecoveryEncryption.seal(original, context: context, key: key)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("Private groceries"))
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains(key))
        XCTAssertEqual(try PantryRecoveryEncryption.context(in: first), context)
        XCTAssertEqual(try PantryRecoveryEncryption.open(first, context: context, key: key), original)
        XCTAssertEqual(try PantryRecoveryEncryption.open(second, context: context, key: key), original)
    }

    func testWrongKeyMovedPartMixedBundleAndAlteredMetadataCannotDecrypt() throws {
        let key = EncryptedArchive.generateKey(), context = PantryRecoveryEncryption.Context(bundleID: UUID(), name: "manifest.json")
        let sealed = try PantryRecoveryEncryption.seal(Data("verified manifest".utf8), context: context, key: key)
        XCTAssertThrowsError(try PantryRecoveryEncryption.open(sealed, context: context, key: EncryptedArchive.generateKey()))
        XCTAssertThrowsError(try PantryRecoveryEncryption.open(sealed, context: .init(bundleID: UUID(), name: context.name), key: key))
        XCTAssertThrowsError(try PantryRecoveryEncryption.open(sealed, context: .init(bundleID: context.bundleID, name: "scope-0.json"), key: key))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        json["context"] = ["bundleID": context.bundleID.uuidString, "name": "scope-0.json"]
        let altered = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try PantryRecoveryEncryption.open(altered, context: .init(bundleID: context.bundleID, name: "scope-0.json"), key: key))
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        var cipher = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(json["combined"] as? String)))
        cipher[cipher.count - 1] ^= 1; json["combined"] = cipher.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try PantryRecoveryEncryption.open(tampered, context: context, key: key))
    }

    func testBoundsNamesUnknownFieldsAndInvalidKeysAreRejected() throws {
        let key = EncryptedArchive.generateKey(), id = UUID()
        for name in ["../manifest.json", "/manifest.json", "pantry-01.json", "scope--1.json", "pantry-0.json/other", "unknown.json"] {
            XCTAssertThrowsError(try PantryRecoveryEncryption.seal(Data([1]), context: .init(bundleID: id, name: name), key: key))
        }
        let context = PantryRecoveryEncryption.Context(bundleID: id, name: "pantry-0.json")
        XCTAssertThrowsError(try PantryRecoveryEncryption.seal(Data([1]), context: context, key: "not a recovery key"))
        XCTAssertThrowsError(try PantryRecoveryEncryption.seal(Data(count: PantryRecoveryEncryption.maximumPlaintextBytes + 1), context: context, key: key))
        let boundary = Data(repeating: 42, count: PantryRecoveryEncryption.maximumPlaintextBytes)
        let sealed = try PantryRecoveryEncryption.seal(boundary, context: context, key: key)
        XCTAssertLessThanOrEqual(sealed.count, PantryRecoveryEncryption.maximumEncryptedBytes)
        XCTAssertEqual(try PantryRecoveryEncryption.open(sealed, context: context, key: key), boundary)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        json["unexpected"] = "unsupported private field"
        let extra = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try PantryRecoveryEncryption.open(extra, context: context, key: key))
    }
}
