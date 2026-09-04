import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("Schema search")
struct SchemaSearchTests {
  private let gmail = GatewaySchemaSearch(catalog: FixtureCatalogs.gmail)
  private let documents = GatewaySchemaSearch(catalog: FixtureCatalogs.documents)

  @Test("exact whole-name matches sort ahead of substring matches, then by kind and name")
  func ordering() throws {
    let matches = try gmail.search("thread")
    #expect(matches.map(\.name) == ["thread", "threads", "Message", "Thread", "ThreadConnection"])
    #expect(matches.map(\.kind) == [.query, .query, .object, .object, .object])
  }

  @Test("operations carry their tier and types do not")
  func tiers() throws {
    let matches = try gmail.search("thread")
    #expect(matches[0].tier == "reader")
    #expect(matches[1].tier == "reader")
    #expect(matches[2].tier == nil)
    #expect(try gmail.search("^sendMessage$").first?.tier == "sender")
  }

  @Test("each match carries the definition's SDL fragment")
  func sdlFragmentAttached() throws {
    let match = try #require(try gmail.search("^PageInfo$").first)
    #expect(match.sdl == FixtureCatalogs.gmail.sdlFragment(for: .object, name: "PageInfo"))
    #expect(match.sdl.hasPrefix("type PageInfo {"))
  }

  @Test("name label")
  func nameLabel() throws {
    #expect(try gmail.search("^PageInfo$").map(\.matchedOn) == [["name"]])
  }

  @Test("argument label on operations and on object field arguments")
  func argumentLabels() throws {
    let byAccount = try gmail.search("^accountId$")
    // No exact name match, so ordering is kind order then name.
    #expect(byAccount.map(\.name) == ["thread", "threads", "sendMessage"])
    #expect(byAccount.allSatisfy { $0.matchedOn == ["argument:accountId"] })

    let byFormat = try gmail.search("^format$")
    #expect(byFormat.map(\.name) == ["Message"])
    #expect(byFormat.map(\.matchedOn) == [["argument:format"]])
  }

  @Test("field label on object fields and on input object fields")
  func fieldLabels() throws {
    let matches = try gmail.search("^subject$")
    #expect(matches.map(\.name) == ["Thread", "SendMessageInput"])
    #expect(matches.map(\.matchedOn) == [["field:subject"], ["field:subject"]])
  }

  @Test("value label on enum values")
  func valueLabel() throws {
    let matches = try documents.search("ROWS")
    #expect(matches.map(\.name) == ["Dimension"])
    #expect(matches.map(\.matchedOn) == [["value:ROWS"]])
  }

  @Test("summary label covers operation summaries and every description text")
  func summaryLabel() throws {
    // Only the sendMessage argument description carries this word.
    let byArgumentDescription = try gmail.search("envelope to deliver")
    #expect(byArgumentDescription.map(\.name) == ["sendMessage"])
    #expect(byArgumentDescription.map(\.matchedOn) == [["summary"]])

    // Only the threads operation summary carries this phrase.
    let bySummary = try gmail.search("List mail threads")
    #expect(bySummary.map(\.name) == ["threads"])
    #expect(bySummary.map(\.matchedOn) == [["summary"]])

    // A type description and a field description.
    #expect(try gmail.search("mail conversation").map(\.name) == ["Thread"])
    #expect(try gmail.search("Subject line").map(\.matchedOn) == [["summary"]])
  }

  @Test("summary is reported once even when several texts match")
  func summaryDeduplicated() throws {
    let matches = try gmail.search("account")
    let threads = try #require(matches.first { $0.name == "threads" })
    #expect(threads.matchedOn == ["argument:accountId", "summary"])
  }

  @Test("kinds filter restricts the searched definitions")
  func kindsFilter() throws {
    let options = GatewaySchemaSearch.Options(kinds: [.enumeration])
    #expect(try gmail.search("[Dd]irection", options: options).map(\.name) == ["Direction"])

    let queriesOnly = GatewaySchemaSearch.Options(kinds: [.query])
    #expect(try gmail.search("thread", options: queriesOnly).map(\.name) == ["thread", "threads"])

    let commandsOnly = GatewaySchemaSearch.Options(kinds: [.command])
    #expect(try documents.search("files", options: commandsOnly).map(\.name) == ["files delete", "files list"])
  }

  @Test("scalars are excluded by default and searchable when asked for")
  func scalarKind() throws {
    #expect(try gmail.search("DateTime").isEmpty)
    let options = GatewaySchemaSearch.Options(kinds: [.scalar])
    #expect(try gmail.search("DateTime", options: options).map(\.name) == ["DateTime"])
  }

  @Test("includeReferencedTypes expands arguments transitively and results one level")
  func referencedTypes() throws {
    let options = GatewaySchemaSearch.Options(includeReferencedTypes: true)
    let matches = try gmail.search("^sendMessage$", options: options)
    #expect(matches.map(\.name) == [
      "sendMessage", "SendMessagePayload", "SendMessageInput", "Direction", "DateTime"
    ])
    #expect(matches.map(\.kind) == [.mutation, .object, .inputObject, .enumeration, .scalar])
    // Direction is only reachable through SendMessageInput's input fields.
    #expect(matches[3].matchedOn == ["referenced-by:sendMessage"])
    // DateTime is a custom scalar on the result object's fields; builtin ID is not listed.
    #expect(matches[4].matchedOn == ["referenced-by:sendMessage"])
    #expect(!matches.contains { $0.name == "ID" || $0.name == "String" })
    #expect(matches.allSatisfy { $0.tier == nil || $0.name == "sendMessage" })
  }

  @Test("referenced types are appended after direct matches and are not kinds-filtered")
  func referencedTypesBypassKindsFilter() throws {
    let options = GatewaySchemaSearch.Options(kinds: [.mutation], includeReferencedTypes: true)
    let matches = try gmail.search("^sendMessage$", options: options)
    #expect(matches.map(\.name) == [
      "sendMessage", "SendMessagePayload", "SendMessageInput", "Direction", "DateTime"
    ])
  }

  @Test("a type referenced by several operations gets one entry with merged sorted labels")
  func referencedByMerged() throws {
    let options = GatewaySchemaSearch.Options(kinds: [.query, .mutation], includeReferencedTypes: true)
    let matches = try gmail.search("^threads$|^sendMessage$", options: options)
    #expect(matches.map(\.name).prefix(2) == ["threads", "sendMessage"])
    let direction = try #require(matches.first { $0.name == "Direction" })
    #expect(direction.matchedOn == ["referenced-by:sendMessage", "referenced-by:threads"])
    #expect(matches.filter { $0.name == "Direction" }.count == 1)
  }

  @Test("a referenced type that is already a direct match is not duplicated")
  func referencedTypesDeduplicatedAgainstDirectMatches() throws {
    let options = GatewaySchemaSearch.Options(includeReferencedTypes: true)
    let matches = try gmail.search("^sendMessage$|^SendMessageInput$", options: options)
    #expect(matches.filter { $0.name == "SendMessageInput" }.count == 1)
    // It keeps its direct-match label rather than being replaced by a referenced-by entry.
    let input = try #require(matches.first { $0.name == "SendMessageInput" })
    #expect(input.matchedOn == ["name"])
  }

  @Test("limit truncates the final ordered list, referenced types included")
  func limit() throws {
    #expect(try gmail.search("thread", options: .init(limit: 2)).map(\.name) == ["thread", "threads"])
    #expect(try gmail.search("thread", options: .init(limit: 0)).isEmpty)
    #expect(try gmail.search("thread", options: .init(limit: 99)).count == 5)

    let options = GatewaySchemaSearch.Options(includeReferencedTypes: true, limit: 2)
    #expect(try gmail.search("^sendMessage$", options: options).map(\.name) == [
      "sendMessage", "SendMessagePayload"
    ])
  }

  @Test("an invalid pattern throws invalidPattern")
  func invalidPattern() {
    #expect {
      _ = try gmail.search("[")
    } throws: { error in
      error as? GatewaySDKError == .invalidPattern("search pattern syntax is incomplete")
    }
  }

  @Test("the admission policy rejects bounded unsafe structures through public search")
  func rejectedPatternStructures() {
    let repeatedAlternation = String(repeating: "(a|aa)", count: 24) + "Z"
    let exactly257UTF8 = String(repeating: "é", count: 128) + "a"
    #expect(repeatedAlternation.utf8.count == 145)
    #expect(exactly257UTF8.utf8.count == 257)

    let cases: [(pattern: String, reason: String)] = [
      ("(.+)+Z", "search pattern does not support unbounded quantifiers"),
      (".*.*.*.*.*.*.*.*Z", "search pattern does not support unbounded quantifiers"),
      ("(a|aa)", "search pattern does not support grouped alternation"),
      ("((a|aa))", "search pattern does not support grouped alternation"),
      (repeatedAlternation, "search pattern does not support grouped alternation"),
      ("a**", "search pattern does not support unbounded quantifiers"),
      ("a+?", "search pattern does not support unbounded quantifiers"),
      ("a?+", "search pattern does not support unbounded quantifiers"),
      ("a+b*", "search pattern does not support unbounded quantifiers"),
      ("a+Z", "search pattern does not support unbounded quantifiers"),
      (".*Z", "search pattern does not support unbounded quantifiers"),
      ("a??", "search pattern allows at most one optional quantifier"),
      ("(ab)?", "search pattern does not support quantified groups"),
      ("a{1,3}", "search pattern does not support counted quantifiers"),
      ("(a)\\1", "search pattern does not support backreferences"),
      ("(a)\\9", "search pattern does not support backreferences"),
      ("(a)\\k<a>", "search pattern does not support backreferences"),
      ("(a)\\k'name'", "search pattern does not support backreferences"),
      ("(a)\\g<a>", "search pattern does not support backreferences"),
      ("(?=a)", "search pattern does not support extension groups"),
      ("(?!a)", "search pattern does not support extension groups"),
      ("(?<=a)", "search pattern does not support extension groups"),
      ("(?i)a", "search pattern does not support extension groups"),
      ("(?:a)", "search pattern does not support extension groups"),
      ("(?<name>a)", "search pattern does not support extension groups"),
      ("abc)", "search pattern has an unmatched closing delimiter"),
      ("abc]", "search pattern has an unmatched closing delimiter"),
      ("foo\\", "search pattern syntax is incomplete"),
      ("[abc", "search pattern syntax is incomplete"),
      ("(abc", "search pattern syntax is incomplete"),
      (String(repeating: "a", count: 257), "search pattern exceeds 256 UTF-8 bytes"),
      (exactly257UTF8, "search pattern exceeds 256 UTF-8 bytes")
    ]

    for testCase in cases {
      #expect {
        _ = try gmail.search(testCase.pattern)
      } throws: { error in
        error as? GatewaySDKError == .invalidPattern(testCase.reason)
      }
    }

    let hostileCatalog = GatewaySchemaCatalog(
      provider: "test",
      tier: "reader",
      operations: [
        GatewayOperation(name: String(repeating: "a", count: 48), kind: .query, tier: "reader")
      ],
      types: []
    )
    #expect {
      _ = try GatewaySchemaSearch(catalog: hostileCatalog).search(repeatedAlternation)
    } throws: { error in
      error as? GatewaySDKError == .invalidPattern("search pattern does not support grouped alternation")
    }

    let repetitiveCatalog = GatewaySchemaCatalog(
      provider: "test",
      tier: "reader",
      operations: [
        GatewayOperation(
          name: "safe",
          kind: .query,
          tier: "reader",
          summary: String(repeating: "a", count: 12_000)
        )
      ]
    )
    for pattern in ["a+Z", ".*Z"] {
      #expect {
        _ = try GatewaySchemaSearch(catalog: repetitiveCatalog).search(pattern)
      } throws: { error in
        error as? GatewaySDKError == .invalidPattern("search pattern does not support unbounded quantifiers")
      }
    }
  }

  @Test("the admission policy retains the documented safe subset")
  func admittedPatternStructures() throws {
    let exactly256ASCII = String(repeating: "a", count: 256)
    let exactly256UTF8 = String(repeating: "é", count: 128)
    #expect(exactly256ASCII.utf8.count == 256)
    #expect(exactly256UTF8.utf8.count == 256)

    let patterns = [
      "", "thread", "スレッド", "^sendMessage$", ".", "[Dd]irection", "((thread))",
      "^threads$|^sendMessage$", "thread?", "\\|", "[|]", "[\\]]", "[(){}*+?]", "\\\\1",
      exactly256ASCII, exactly256UTF8
    ]
    for pattern in patterns {
      _ = try gmail.search(pattern)
    }
  }

  @Test("compiler failures after admission keep the stable invalid-pattern case")
  func compilerFallback() {
    #expect {
      _ = try gmail.search("[z-a]")
    } throws: { error in
      guard case .invalidPattern = error as? GatewaySDKError else { return false }
      return (error as? GatewaySDKError)?.description.hasPrefix("invalid search pattern:") == true
    }
  }

  @Test("no matches yields an empty list")
  func noMatches() throws {
    #expect(try gmail.search("zzz-not-present").isEmpty)
  }

  @Test("Match round trips through Codable")
  func matchCodable() throws {
    let match = try #require(try gmail.search("^threads$").first)
    let data = try JSONEncoder().encode(match)
    #expect(try JSONDecoder().decode(GatewaySchemaSearch.Match.self, from: data) == match)
  }
}
