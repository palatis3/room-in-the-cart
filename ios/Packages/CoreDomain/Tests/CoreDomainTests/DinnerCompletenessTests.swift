import XCTest
@testable import CoreDomain
final class DinnerCompletenessTests: XCTestCase {
 func q(_ n:Int64,_ unit:UnitOfMeasure = .count,_ basis:UnitBasis? = nil) throws ->Quantity { Quantity(amount:try Rational(n),unit:unit,originalLiteral:"entered",confirmedConversion:basis) }
 func scenario(_ dinner:AcceptedDinner,_ needs:[DinnerDemand],_ commitments:DinnerCommitmentSet,_ packs:[DinnerPackSelection]) -> DinnerScenario {
  DinnerScenario(commitments:commitments,acceptedDinnerIDs:[dinner.id],demands:needs,packs:packs,baselineComplete:true,fees:[],tax:.exact(.zero),deposits:.exact(.zero),context:.init(storeID:"A",branchID:"A",mode:.pickup,slot:"today",commitmentsID:commitments.id,observedAt:Date(),source:"reviewed"),preparation:.init(handsOnMinutes:5,remainingLeadMinutes:5,availableMinutes:20))
 }
 func testOmittedRequiredIngredientCannotClaimCoverage() throws {
  let dinner=AcceptedDinner(id: UUID(), template:MealTemplate(title:"Bean wraps",servings:try Rational(1),ingredients:[MealIngredient(name:"wraps",quantity:try q(1)),MealIngredient(name:"beans",quantity:try q(1))]),acceptedAt:Date())
  let c=DinnerCommitmentSet(commitments:[.init(name:"Dinner",kind:.dinner,portions:try Rational(1))]); let food=UUID()
  let needs=[DinnerDemand(commitmentID:c.commitments[0].id,foodID:food,name:"wraps",quantity:try q(1),acceptedDinnerID:dinner.id,ingredientID:dinner.template.ingredients[0].id)]
  let packs=[DinnerPackSelection(foodID:food,offer:.init(id:"wrap",label:"wrap",usableQuantity:try q(1),price:Money(minorUnits:100)),availability:.confirmed(maximumPacks:1))]
  let result=try DinnerScenarioEngine.evaluate(scenario(dinner,needs,c,packs),acceptedDinners:[dinner])
  XCTAssertFalse(result.foodCoverageComplete,"Missing beans must not count as a complete bean-wrap dinner")
  XCTAssertNil(result.checkout.total.exact, "Omitting required food must not certify a complete checkout total")
 }
 func testConfirmedFoodBasisSurvivesDemandAggregation() throws {
  let basis=UnitBasis(sourceUnit:.cup,targetUnit:.gram,targetAmountPerSourceUnit:try Rational(120),sourceNote:"Confirmed for this flour")
  let dinner=AcceptedDinner(id: UUID(), template:MealTemplate(title:"Flour dinner",ingredients:[MealIngredient(name:"flour",quantity:try q(120,.gram))]),acceptedAt:Date())
  let c=DinnerCommitmentSet(commitments:[.init(name:"Dinner",kind:.dinner,portions:try Rational(1)),.init(name:"Lunch",kind:.lunch,portions:try Rational(1),protected:true)]);let food=UUID()
  let needs=[DinnerDemand(commitmentID:c.commitments[0].id,foodID:food,name:"flour",quantity:try q(120,.gram),acceptedDinnerID:dinner.id,ingredientID:dinner.template.ingredients[0].id),DinnerDemand(commitmentID:c.commitments[1].id,foodID:food,name:"flour",quantity:try q(1,.cup,basis),acceptedDinnerID:dinner.id,ingredientID:dinner.template.ingredients[0].id)]
  let packs=[DinnerPackSelection(foodID:food,offer:.init(id:"flour",label:"Flour",usableQuantity:try q(240,.gram),price:Money(minorUnits:100)),availability:.confirmed(maximumPacks:1))]
  let result=try DinnerScenarioEngine.evaluate(scenario(dinner,needs,c,packs),acceptedDinners:[dinner])
  XCTAssertTrue(result.foodCoverageComplete,"Explicitly confirmed flour conversion must remain available: \(result.issues)")
 }
 func testCompleteIngredientBindingsCanProveCoverage() throws {
  let dinner=AcceptedDinner(id:UUID(),template:MealTemplate(title:"Bean wraps",ingredients:[MealIngredient(name:"wraps",quantity:try q(1)),MealIngredient(name:"beans",quantity:try q(1))]),acceptedAt:Date())
  let c=DinnerCommitmentSet(commitments:[.init(name:"Dinner",kind:.dinner,portions:try Rational(1))])
  let foods=[UUID(),UUID()]
  let needs=try dinner.template.ingredients.enumerated().map { i,ingredient in DinnerDemand(commitmentID:c.commitments[0].id,foodID:foods[i],name:ingredient.name,quantity:try q(1),acceptedDinnerID:dinner.id,ingredientID:ingredient.id) }
  let packs=try foods.enumerated().map { i,food in DinnerPackSelection(foodID:food,offer:.init(id:"pack-\(i)",label:"Reviewed pack",usableQuantity:try q(1),price:Money(minorUnits:100)),availability:.confirmed(maximumPacks:1)) }
  let result=try DinnerScenarioEngine.evaluate(scenario(dinner,needs,c,packs),acceptedDinners:[dinner])
  XCTAssertTrue(result.foodCoverageComplete); XCTAssertEqual(result.checkout.total.exact?.minorUnits,200)
 }
 func testLegacyUnboundDemandDecodesButCannotCertifyCompleteMeal() throws {
  let dinner=AcceptedDinner(id:UUID(),template:MealTemplate(title:"Wraps",ingredients:[MealIngredient(name:"wraps",quantity:try q(1))]),acceptedAt:Date())
  let c=DinnerCommitmentSet(commitments:[.init(name:"Dinner",kind:.dinner,portions:try Rational(1))]);let food=UUID()
  let demand=DinnerDemand(commitmentID:c.commitments[0].id,foodID:food,name:"wraps",quantity:try q(1),acceptedDinnerID:dinner.id)
  let decoded=try JSONDecoder().decode(DinnerDemand.self,from:JSONEncoder().encode(demand))
  XCTAssertNil(decoded.ingredientID)
  let packs=[DinnerPackSelection(foodID:food,offer:.init(id:"wraps",label:"Wraps",usableQuantity:try q(1),price:Money(minorUnits:100)),availability:.confirmed(maximumPacks:1))]
  let result=try DinnerScenarioEngine.evaluate(scenario(dinner,[decoded],c,packs),acceptedDinners:[dinner])
  XCTAssertFalse(result.foodCoverageComplete); XCTAssertNil(result.checkout.total.exact)
 }
 func testForeignIngredientBindingFailsClosed() throws {
  let dinner=AcceptedDinner(id:UUID(),template:MealTemplate(title:"Wraps",ingredients:[MealIngredient(name:"wraps",quantity:try q(1))]),acceptedAt:Date())
  let c=DinnerCommitmentSet(commitments:[.init(name:"Dinner",kind:.dinner,portions:try Rational(1))]);let food=UUID()
  let demand=DinnerDemand(commitmentID:c.commitments[0].id,foodID:food,name:"wraps",quantity:try q(1),acceptedDinnerID:dinner.id,ingredientID:UUID())
  XCTAssertThrowsError(try DinnerScenarioEngine.evaluate(scenario(dinner,[demand],c,[]),acceptedDinners:[dinner]))
 }

 func testZeroOrUndersizedRequiredIngredientCannotClaimCoverage() throws {
  for quantity in [Int64(0),Int64(1)] {
   let dinner=AcceptedDinner(id:UUID(),template:MealTemplate(title:"Bean wraps",servings:try Rational(1),ingredients:[MealIngredient(name:"wraps",quantity:try q(1)),MealIngredient(name:"beans",quantity:try q(2))]),acceptedAt:Date())
   let c=DinnerCommitmentSet(commitments:[.init(name:"Dinner",kind:.dinner,portions:try Rational(1))]); let foods=[UUID(),UUID()]
   let demands=try dinner.template.ingredients.enumerated().map { i,ingredient in DinnerDemand(commitmentID:c.commitments[0].id,foodID:foods[i],name:ingredient.name,quantity:try q(i == 0 ? 1 : quantity),acceptedDinnerID:dinner.id,ingredientID:ingredient.id) }
   let packs=try foods.enumerated().map { i,food in DinnerPackSelection(foodID:food,offer:.init(id:"pack-\(i)",label:"Pack",usableQuantity:try q(2),price:Money(minorUnits:100)),availability:.confirmed(maximumPacks:nil)) }
   let result=try DinnerScenarioEngine.evaluate(scenario(dinner,demands,c,packs),acceptedDinners:[dinner])
   XCTAssertFalse(result.foodCoverageComplete); XCTAssertNil(result.checkout.total.exact)
  }
 }
 func testRecipeYieldMustCoverRequestedPortions() throws {
  let dinner=AcceptedDinner(id:UUID(),template:MealTemplate(title:"Wraps",servings:try Rational(2),ingredients:[MealIngredient(name:"wraps",quantity:try q(2))]),acceptedAt:Date())
  let c=DinnerCommitmentSet(commitments:[.init(name:"Dinner",kind:.dinner,portions:try Rational(8))]);let food=UUID()
  let demand=DinnerDemand(commitmentID:c.commitments[0].id,foodID:food,name:"wraps",quantity:try q(2),acceptedDinnerID:dinner.id,ingredientID:dinner.template.ingredients[0].id)
  let pack=DinnerPackSelection(foodID:food,offer:.init(id:"wraps",label:"Wraps",usableQuantity:try q(8),price:Money(minorUnits:100)),availability:.confirmed(maximumPacks:1))
  let result=try DinnerScenarioEngine.evaluate(scenario(dinner,[demand],c,[pack]),acceptedDinners:[dinner])
  XCTAssertFalse(result.foodCoverageComplete); XCTAssertNil(result.checkout.total.exact)
 }

}
