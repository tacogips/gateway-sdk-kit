import Testing
@testable import GatewaySDKKit

private struct UnrecognizedResolverError: Error {}

private actor CallRecorder {
  private var calls = 0
  private var inFlight = 0
  private var maximum = 0
  private var arguments: [[String: GatewayJSONValue]] = []

  func begin(arguments: [String: GatewayJSONValue]) {
    calls += 1; inFlight += 1; maximum = max(maximum, inFlight)
    self.arguments.append(arguments)
  }
  func end() { inFlight -= 1 }
  func snapshot() -> (Int, Int) { (calls, maximum) }
  func recordedArguments() -> [[String: GatewayJSONValue]] { arguments }
}

private actor ResolverBarrier {
  let threshold: Int
  private var arrivals = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(threshold: Int) { self.threshold = threshold }

  func wait() async {
    arrivals += 1
    guard arrivals < threshold else {
      let pending = waiters
      waiters.removeAll()
      pending.forEach { $0.resume() }
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }
}

private actor ErrorOrderGate {
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?

  func waitForSecondFailure() async {
    guard !released else { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func releaseFirstFailure() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

private struct ExpectedResolverError: GatewayResolverError {
  let code = "EXPECTED"
  let message = "expected resolver failure"
}

private struct SecretResolverError: Error, CustomStringConvertible {
  var description: String { "resolver secret MUST_NOT_LEAK" }
}

@Suite("GraphQL runtime")
struct GraphQLRuntimeTests {
  @Test("projects aliases, lists, missing keys, and the envelope")
  func projectsResults() async throws {
    let runtime = try makeRuntime()
    let envelope = await runtime.execute(
      document: #"{ labels(accountId: "a1") { title: name id } }"#,
      context: .init(requestId: "r1")
    )
    #expect(envelope.exitCode == 0)
    #expect(envelope.data == .object(["labels": .array([.object(["title": .string("Inbox"), "id": .string("l1")])])]))
    #expect(envelope.rawOutput.contains("\"requestId\":\"r1\""))
  }

  @Test("passes coerced literal and variable-default arguments to resolvers")
  func recordsCoercedArguments() async throws {
    let recorder = CallRecorder()
    let runtime = try makeRuntime(recorder: recorder)
    let literal = await runtime.execute(
      document: #"{ threads(input: {accountId: "a", direction: INBOUND}) { totalCount } }"#,
      context: .init()
    )
    #expect(literal.exitCode == 0)
    #expect(await recorder.recordedArguments().first == [
      "input": .object(["accountId": .string("a"), "direction": .string("INBOUND"), "limit": .int(25)])
    ])

    let variables = await runtime.execute(
      document: "query($id: ID!, $limit: Int = 7) { threads(input: {accountId: $id, limit: $limit}) { totalCount } }",
      variables: ["id": .string("b")],
      context: .init()
    )
    #expect(variables.exitCode == 0)
    #expect(await recorder.recordedArguments().last == [
      "input": .object(["accountId": .string("b"), "limit": .int(7)])
    ])
  }

  @Test("fails authorization before any resolver call")
  func deniesWithoutCall() async throws {
    let recorder = CallRecorder()
    let authorized = GatewaySchemaCatalog(provider: "runtime-fixture", tier: "reader", operations: [FixtureCatalogs.runtime.operations[1]], types: FixtureCatalogs.runtime.types)
    let runtime = try makeRuntime(recorder: recorder, authorized: authorized)
    let envelope = await runtime.execute(document: #"{ threads(input: {accountId: "a"}) { totalCount } }"#, context: .init())
    #expect(envelope.exitCode == 1)
    #expect(envelope.errors.first?.code == "CAPABILITY_DENIED")
    #expect(await recorder.snapshot().0 == 0)
    #expect(runtime.printedSchema().contains("labels"))
    #expect(!runtime.printedSchema().contains("threads"))
  }

  @Test("denies mixed authorization before calling any resolver")
  func deniesMixedRequestWithoutCalls() async throws {
    let recorder = CallRecorder()
    let authorized = GatewaySchemaCatalog(
      provider: "runtime-fixture",
      tier: "reader",
      operations: [FixtureCatalogs.runtime.operations[0]],
      types: FixtureCatalogs.runtime.types
    )
    let runtime = try makeRuntime(recorder: recorder, authorized: authorized)
    let envelope = await runtime.execute(
      document: #"{ threads(input: {accountId: "a"}) { totalCount } labels(accountId: "a") { name } }"#,
      context: .init()
    )
    #expect(envelope.exitCode == 1)
    #expect(envelope.data == nil)
    #expect(envelope.errors.map(\.code) == ["CAPABILITY_DENIED"])
    #expect(envelope.errors.first?.path == ["labels"])
    #expect(await recorder.snapshot().0 == 0)
  }

  @Test("returns partial query data and redacts unknown failures")
  func partialFailures() async throws {
    let runtime = try makeRuntime(labels: { _, _ in throw ExpectedResolverError() }, threads: { _, _ in throw SecretResolverError() })
    let envelope = await runtime.execute(document: #"{ labels(accountId: "a") { name } threads(input: {accountId: "a"}) { totalCount } }"#, context: .init())
    #expect(envelope.exitCode == 1)
    #expect(envelope.data == .object(["labels": .null, "threads": .null]))
    #expect(envelope.errors.map(\.code) == ["EXPECTED", "RESOLVER_ERROR"])
    #expect(!envelope.rawOutput.contains("MUST_NOT_LEAK"))
    #expect(envelope.errors.last?.message == "resolver failed")
  }

  @Test("executes a single mutation and projects resolver shape failures")
  func mutationAndShapeFailure() async throws {
    let runtime = try makeRuntime(labels: { _, _ in .object([:]) })
    let mutation = await runtime.execute(document: #"mutation { sendMessage(input: {accountId: "a", to: ["b"], body: "hello"}) { messageId } }"#, context: .init())
    #expect(mutation.exitCode == 0)
    #expect(mutation.data == .object(["sendMessage": .object(["messageId": .string("m1")])]))
    let malformed = await runtime.execute(document: #"{ labels(accountId: "a") { name } }"#, context: .init())
    #expect(malformed.errors.first?.code == "RESOLVER_SHAPE")
    #expect(malformed.errors.first?.path == ["labels"])
    let nullRuntime = try makeRuntime(labels: { _, _ in .null })
    let nullResult = await nullRuntime.execute(document: #"{ labels(accountId: "a") { name } }"#, context: .init())
    #expect(nullResult.exitCode == 0)
    #expect(nullResult.data == .object(["labels": .null]))
  }

  @Test("rejects invalid mutations before calling resolvers")
  func rejectsMultipleMutationsWithoutCalls() async throws {
    let recorder = CallRecorder()
    let runtime = try makeRuntime(recorder: recorder)
    let document = #"mutation { a: sendMessage(input: {accountId: "a", to: ["b"], body: "x"}) { messageId } b: sendMessage(input: {accountId: "a", to: ["b"], body: "x"}) { messageId } }"#
    let envelope = await runtime.execute(document: document, context: .init())
    let snapshot = await recorder.snapshot()
    #expect(envelope.exitCode == 2)
    #expect(envelope.errors.first?.code == "MULTIPLE_MUTATIONS")
    #expect(snapshot.0 == 0)
  }

  @Test("rejects hostile duplicate documents before resolver invocation")
  func rejectsDuplicateDocumentsWithoutCalls() async throws {
    let recorder = CallRecorder()
    let runtime = try makeRuntime(recorder: recorder)
    let documents = [
      #"query($id: ID, $id: ID) { labels(accountId: $id) { name } }"#,
      #"{ labels(accountId: "a", accountId: "b") { name } }"#,
      #"{ threads(input: {accountId: "a"}) { edges { node(unused: 1) { id } } } }"#
    ]
    for document in documents {
      let envelope = await runtime.execute(document: document, context: .init())
      #expect(envelope.exitCode == 2)
      #expect(await recorder.snapshot().0 == 0)
    }
  }

  @Test("round-trips successful raw output and validates resolver tables")
  func roundTripAndResolverTable() async throws {
    let runtime = try makeRuntime()
    let envelope = await runtime.execute(document: #"{ labels(accountId: "a") { name } }"#, context: .init(requestId: "round-trip"))
    let roundTrip = GatewayEnvelope(parsingCLIOutput: envelope.rawOutput, exitCode: envelope.exitCode)
    #expect(roundTrip.data == envelope.data)
    #expect(roundTrip.errors == envelope.errors)
    #expect(roundTrip.requestId == envelope.requestId)
    let problems = GatewayGraphQLRuntime.check(catalog: FixtureCatalogs.runtime, resolvers: ["labels": { _, _ in .array([]) }, "extra": { _, _ in .null }])
    #expect(problems == ["missing resolver for root field 'sendMessage'", "missing resolver for root field 'threads'", "resolver 'extra' matches no catalog root field"])
    #expect(throws: GatewaySDKError.self) {
      _ = try GatewayGraphQLRuntime(catalog: FixtureCatalogs.runtime, resolvers: [:])
    }
    #expect(throws: GatewaySDKError.self) {
      _ = try GatewayGraphQLRuntime(catalog: FixtureCatalogs.runtime, resolvers: [
        "labels": { _, _ in .array([]) },
        "threads": { _, _ in .object([:]) },
        "sendMessage": { _, _ in .object([:]) },
        "extra": { _, _ in .null }
      ])
    }
  }

  @Test("uses the documented envelope codes for success syntax and validation")
  func envelopeCodeMatrix() async throws {
    let runtime = try makeRuntime()
    let success = await runtime.execute(document: #"{ labels(accountId: "a") { name } }"#, context: .init(requestId: "success"))
    #expect(success.exitCode == 0)
    #expect(success.errors.isEmpty)
    #expect(success.rawOutput.contains("\"errors\":[]"))
    #expect(success.rawOutput.contains("\"extensions\":{\"requestId\":\"success\"}"))

    let syntax = await runtime.execute(document: "{", context: .init())
    #expect(syntax.exitCode == 2)
    #expect(syntax.errors.first?.code == "SYNTAX")
    let validation = await runtime.execute(document: "{ missing }", context: .init())
    #expect(validation.exitCode == 2)
    #expect(validation.errors.first?.code == "UNKNOWN_FIELD")
  }

  @Test("limits seven, eight, and nine concurrent query resolvers")
  func limitsConcurrentQueries() async throws {
    for count in [7, 8, 9] {
      let recorder = CallRecorder()
      let barrier = ResolverBarrier(threshold: min(count, GatewayGraphQLLimits.concurrentQueryResolvers))
      let runtime = try makeRuntime(recorder: recorder, labels: { _, _ in
        await barrier.wait()
        return .array([.object(["name": .string("Inbox")])])
      })
      let selections = (0..<count).map { #"q\#($0): labels(accountId: "a") { name }"# }.joined(separator: " ")
      let envelope = await runtime.execute(document: "{ \(selections) }", context: .init())
      let snapshot = await recorder.snapshot()
      #expect(envelope.exitCode == 0)
      #expect(snapshot.0 == count)
      #expect(snapshot.1 == min(count, 8))
    }
  }

  @Test("keeps concurrent error order in document order")
  func preservesErrorOrder() async throws {
    let gate = ErrorOrderGate()
    let runtime = try makeRuntime(labels: { arguments, _ in
      guard case .string(let id)? = arguments["accountId"] else { return .array([]) }
      if id == "first" { await gate.waitForSecondFailure(); throw ExpectedResolverError() }
      if id == "second" { await gate.releaseFirstFailure(); throw ExpectedResolverError() }
      return .array([.object(["name": .string(id)])])
    })
    let envelope = await runtime.execute(document: #"{ first: labels(accountId: "first") { name } second: labels(accountId: "second") { name } third: labels(accountId: "third") { name } }"#, context: .init())
    #expect(envelope.errors.map { $0.path } == [["first"], ["second"]])
    #expect(envelope.data == .object(["first": .null, "second": .null, "third": .array([.object(["name": .string("third")])])]))
  }

  @Test("enforces resolver container boundaries at the selected response path")
  func reportsResourcePath() async throws {
    for count in [GatewayGraphQLLimits.containerEntries - 1, GatewayGraphQLLimits.containerEntries, GatewayGraphQLLimits.containerEntries + 1] {
      let result = GatewayJSONValue.array((0..<count).map { _ in .object(["name": .string("x")]) })
      let runtime = try makeRuntime(labels: { _, _ in result })
      let envelope = await runtime.execute(document: #"{ visible: labels(accountId: "a") { name } }"#, context: .init())
      if count > GatewayGraphQLLimits.containerEntries {
        #expect(envelope.errors.first?.code == "RESOLVER_SHAPE")
        #expect(envelope.errors.first?.path == ["visible"])
      } else {
        #expect(envelope.exitCode == 0)
      }
    }
  }

  @Test("enforces resolver depth and node boundaries")
  func resolverDepthAndNodeBoundaries() {
    for levels in [GatewayGraphQLLimits.depth - 2, GatewayGraphQLLimits.depth - 1, GatewayGraphQLLimits.depth] {
      var value: GatewayJSONValue = .int(1)
      for _ in 0..<levels { value = .array([value]) }
      let result = GatewayGraphQLProjection.project(value, selection: [], type: .named("JSON"), catalog: FixtureCatalogs.runtime, path: ["value"])
      if levels >= GatewayGraphQLLimits.depth {
        guard case .failure(let error) = result else { Issue.record("expected depth failure"); continue }
        #expect(error.path == ["value"])
      } else {
        guard case .value = result else { Issue.record("expected accepted depth"); continue }
      }
    }
    for finalCount in [988, 989, 990] {
      let groups = Array(repeating: GatewayJSONValue.array(Array(repeating: .int(1), count: 1_000)), count: 9)
        + [.array(Array(repeating: .int(1), count: finalCount))]
      let result = GatewayGraphQLProjection.project(.array(groups), selection: [], type: .named("JSON"), catalog: FixtureCatalogs.runtime, path: ["value"])
      if finalCount > 989 {
        guard case .failure(let error) = result else { Issue.record("expected node failure"); continue }
        #expect(error.path == ["value"])
      } else {
        guard case .value = result else { Issue.record("expected accepted nodes"); continue }
      }
    }
  }

  private func makeRuntime(
    recorder: CallRecorder? = nil,
    authorized: GatewaySchemaCatalog? = nil,
    labels: @escaping GatewayGraphQLRuntime.Resolver = { _, _ in .array([.object(["id": .string("l1"), "name": .string("Inbox")])]) },
    threads: @escaping GatewayGraphQLRuntime.Resolver = { _, _ in .object(["totalCount": .int(1), "edges": .array([])]) }
  ) throws -> GatewayGraphQLRuntime {
    let labelsWithRecording: GatewayGraphQLRuntime.Resolver = { arguments, context in
      if let recorder { await recorder.begin(arguments: arguments) }
      do {
        let result = try await labels(arguments, context)
        if let recorder { await recorder.end() }
        return result
      } catch {
        if let recorder { await recorder.end() }
        throw error
      }
    }
    let threadsWithRecording: GatewayGraphQLRuntime.Resolver = { arguments, context in
      if let recorder { await recorder.begin(arguments: arguments) }
      do {
        let result = try await threads(arguments, context)
        if let recorder { await recorder.end() }
        return result
      } catch {
        if let recorder { await recorder.end() }
        throw error
      }
    }
    return try GatewayGraphQLRuntime(
      catalog: FixtureCatalogs.runtime,
      authorized: authorized,
      resolvers: [
        "labels": labelsWithRecording,
        "threads": threadsWithRecording,
        "sendMessage": { _, _ in .object(["messageId": .string("m1"), "threadId": .string("t1")]) }
      ]
    )
  }
}
