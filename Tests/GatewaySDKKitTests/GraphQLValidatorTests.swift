import Testing
@testable import GatewaySDKKit

@Suite("GraphQL validator")
struct GraphQLValidatorTests {
  @Test("coerces defaults and validates selections")
  func coercesDefaults() throws {
    let operation = GatewayOperation(name: "count", kind: .query, tier: "reader", arguments: [GatewayArgument(name: "limit", type: .named("Int"), defaultValue: .int(2))], result: .named("Count"))
    let catalog = GatewaySchemaCatalog(provider: "p", tier: "reader", operations: [operation], types: [.init(name: "Count", kind: .object([.init(name: "value", type: .named("Int"))]))])
    let document = try GatewayGraphQLParser.parse("{ count { value } }")
    let validated = try GatewayGraphQLValidator(catalog: catalog).validate(document)
    #expect(validated.rootFields[0].arguments == ["limit": .int(2)])
  }
}
