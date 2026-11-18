import XCTest

@testable import RoomInTheCart

final class MealChoiceWordingTests: XCTestCase {
  func testOnlyRequestLocalSelectedReferencesCanResolveAndNoFactsOrProseAreAccepted() throws {
    let bean = MealChoiceWording.Option(id: UUID(), title: "Tacos de frijoles")
    let rice = MealChoiceWording.Option(id: UUID(), title: "Rice")
    let chosen = try MealChoiceWording(
      words: "Quiero tacos", locale: "es", eligible: [bean, rice], selected: [bean.id])
    let bytes = try JSONEncoder().encode(chosen.payload)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(
      Set(fields.keys),
      ["version", "consent", "issuedAt", "locale", "requestID", "sourceLines", "candidates"])
    let transmitted = try XCTUnwrap(String(data: bytes, encoding: .utf8))
    XCTAssertFalse(transmitted.contains(bean.id.uuidString))
    XCTAssertFalse(transmitted.contains(rice.title))
    let one = try XCTUnwrap(chosen.payload.candidates.first)
    XCTAssertEqual(one.title, bean.title)
    func reply(_ candidate: Any, request: UUID? = nil, additions: [String: Any] = [:]) throws
      -> MealChoiceWording.Reply
    {
      var fields: [String: Any] = [
        "version": 1, "requestID": (request ?? chosen.payload.requestID).uuidString,
        "candidateID": candidate,
      ]
      fields.merge(additions) { _, value in value }
      return try JSONDecoder().decode(
        MealChoiceWording.Reply.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    XCTAssertEqual(try chosen.resolve(reply(one.id.uuidString)), bean)
    XCTAssertNil(try chosen.resolve(reply(NSNull())))
    XCTAssertThrowsError(try chosen.resolve(reply(bean.id.uuidString)))
    XCTAssertThrowsError(try chosen.resolve(reply(one.id.uuidString, request: UUID())))
    XCTAssertThrowsError(
      try chosen.resolve(reply(one.id.uuidString, additions: ["stock": "enough"])))
    let next = try MealChoiceWording(
      words: "Quiero tacos", locale: "es", eligible: [bean], selected: [bean.id])
    XCTAssertNotEqual(next.payload.candidates[0].id, one.id)
    XCTAssertThrowsError(
      try MealChoiceWording(
        words: "Quiero tacos", locale: "es", eligible: [bean], selected: [rice.id]))
  }
}
