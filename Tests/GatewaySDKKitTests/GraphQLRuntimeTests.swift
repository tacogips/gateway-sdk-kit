import Testing
@testable import GatewaySDKKit

@Suite("GraphQL runtime")
struct GraphQLRuntimeTests {
  @Test("projects resolver output into a GraphQL envelope")
  func executes() async throws {
    let operation = GatewayOperation(name: "count", kind: .query, tier: "reader", result: .named("Count"))
    let catalog = GatewaySchemaCatalog(provider: "p", tier: "reader", operations: [operation], types: [.init(name: "Count", kind: .object([.init(name: "value", type: .named("Int"))]))])
    let runtime = try GatewayGraphQLRuntime(catalog: catalog, resolvers: ["count": { _, _ in .object(["value": .int(2), "ignored": .int(3)]) }])
    let envelope = await runtime.execute(document: "{ count { value } }", context: .init(requestId: "r1"))
    #expect(envelope.exitCode == 0)
    #expect(envelope.data == .object(["count": .object(["value": .int(2)])]))
    #expect(envelope.rawOutput.contains("\"requestId\":\"r1\""))
  }
}
