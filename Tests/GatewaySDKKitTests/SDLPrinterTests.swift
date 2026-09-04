import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("SDL printer")
struct SDLPrinterTests {
  @Test("gmail catalog prints the full SDL golden")
  func gmailGolden() {
    let expected = #"""
      """
      An RFC 3339 timestamp.
      """
      scalar DateTime

      """
      Direction of a message relative to the mailbox.
      """
      enum Direction {
        INBOUND
        OUTBOUND
      }

      """
      Envelope accepted by sendMessage.
      """
      input SendMessageInput {
        """
        Recipient addresses.
        """
        to: [String!]!
        subject: String
        direction: Direction
      }

      type EmailAddress {
        address: String!
        name: String
      }

      type Message {
        id: ID!
        snippet: String
        direction: Direction!
        from: EmailAddress
        thread: Thread!
        """
        Raw RFC 822 source in the requested format.
        """
        raw(format: String!): String
      }

      type PageInfo {
        hasNextPage: Boolean!
        endCursor: String
      }

      type SendMessagePayload {
        id: ID!
        sentAt: DateTime
      }

      """
      A mail conversation.
      """
      type Thread {
        id: ID!
        """
        Subject line of the thread.
        """
        subject: String
        messages: [Message!]!
      }

      """
      A page of mail threads.
      """
      type ThreadConnection {
        totalCount: Int!
        pageInfo: PageInfo!
        edges: [ThreadEdge!]!
      }

      type ThreadEdge {
        cursor: String!
        node: Thread!
      }

      type Query {
        """
        List mail threads for an account.
        """
        threads(accountId: ID!, first: Int, direction: Direction): ThreadConnection
        """
        Fetch a single mail thread by identifier.
        """
        thread(accountId: ID!, id: ID!): Thread
      }

      type Mutation {
        """
        Send a message from the account.
        """
        sendMessage(accountId: ID!, input: SendMessageInput!): SendMessagePayload
      }
      """#
    #expect(FixtureCatalogs.gmail.sdl() == expected + "\n")
  }

  @Test("documents command catalog prints type Command with sanitized names")
  func documentsGolden() {
    let expected = #"""
      """
      Spreadsheet major dimension.
      """
      enum Dimension {
        ROWS
        COLUMNS
      }

      """
      Value rendering options.
      """
      input ValueInput {
        majorDimension: Dimension
        values: [String!]
      }

      type File {
        id: ID!
        name: String!
      }

      """
      A page of Drive files.
      """
      type FileList {
        files: [File!]!
        nextPageToken: String
      }

      type Command {
        """
        Read a range of spreadsheet values.
        """
        values_get(spreadsheet_id: ID!, range: String!, major_dimension: Dimension, value_input: ValueInput): JSON
        """
        List files visible to the credential.
        """
        files_list(query: String, page_size: Int, drive_id: ID, fields: [String!]): FileList
        """
        Delete a file permanently.
        """
        files_delete(file_id: ID!, confirm: Boolean): JSON
      }
      """#
    #expect(FixtureCatalogs.documents.sdl() == expected + "\n")
  }

  @Test("sdlFragment prints exactly one query definition wrapped in its root type")
  func queryFragment() {
    let expected = #"""
      type Query {
        """
        List mail threads for an account.
        """
        threads(accountId: ID!, first: Int, direction: Direction): ThreadConnection
      }
      """#
    #expect(FixtureCatalogs.gmail.sdlFragment(for: .query, name: "threads") == expected)
  }

  @Test("sdlFragment prints one mutation, command, object, input, enum and scalar")
  func fragmentsPerKind() {
    let gmail = FixtureCatalogs.gmail
    let documents = FixtureCatalogs.documents

    #expect(gmail.sdlFragment(for: .mutation, name: "sendMessage")?.hasPrefix("type Mutation {") == true)
    #expect(
      documents.sdlFragment(for: .command, name: "files delete") == #"""
        type Command {
          """
          Delete a file permanently.
          """
          files_delete(file_id: ID!, confirm: Boolean): JSON
        }
        """#
    )
    #expect(
      gmail.sdlFragment(for: .object, name: "PageInfo") == """
        type PageInfo {
          hasNextPage: Boolean!
          endCursor: String
        }
        """
    )
    #expect(
      gmail.sdlFragment(for: .inputObject, name: "SendMessageInput") == #"""
        """
        Envelope accepted by sendMessage.
        """
        input SendMessageInput {
          """
          Recipient addresses.
          """
          to: [String!]!
          subject: String
          direction: Direction
        }
        """#
    )
    #expect(
      gmail.sdlFragment(for: .enumeration, name: "Direction") == #"""
        """
        Direction of a message relative to the mailbox.
        """
        enum Direction {
          INBOUND
          OUTBOUND
        }
        """#
    )
    #expect(
      gmail.sdlFragment(for: .scalar, name: "DateTime") == #"""
        """
        An RFC 3339 timestamp.
        """
        scalar DateTime
        """#
    )
  }

  @Test("sdlFragment returns nil for an unknown name or a mismatched kind")
  func fragmentMisses() {
    let gmail = FixtureCatalogs.gmail
    #expect(gmail.sdlFragment(for: .object, name: "Nope") == nil)
    #expect(gmail.sdlFragment(for: .query, name: "sendMessage") == nil)
    #expect(gmail.sdlFragment(for: .command, name: "threads") == nil)
    #expect(gmail.sdlFragment(for: .enumeration, name: "Thread") == nil)
  }

  @Test("root types with no operations are omitted")
  func emptyRootTypesOmitted() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [GatewayOperation(name: "only", kind: .query, tier: "t", result: .named("Int"))]
    )
    #expect(catalog.sdl() == "type Query {\n  only: Int\n}\n")
    #expect(!catalog.sdl().contains("Mutation"))
    #expect(!catalog.sdl().contains("Command"))
  }

  @Test("an empty catalog prints nothing")
  func emptyCatalog() {
    #expect(GatewaySchemaCatalog(provider: "p", tier: "t").sdl() == "")
  }

  // MARK: - Description escaping

  /// Builds a one-object catalog whose single field carries `description`.
  private func catalog(fieldDescription: String) -> GatewaySchemaCatalog {
    GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      types: [
        GatewayNamedType(
          name: "Thing",
          kind: .object([
            GatewayField(name: "id", type: .nonNull(.named("ID")), description: fieldDescription)
          ])
        )
      ]
    )
  }

  @Test("a description containing a block-string delimiter is escaped, not left to close the block")
  func descriptionWithBlockDelimiterIsEscaped() throws {
    // Without the escape the embedded `"""` closes the block, `}` closes `type Thing`
    // early, and `type Injected` becomes a top-level definition in the schema an agent
    // reads. Descriptions are the only untrusted channel here that is not name-sanitized.
    let injection = #"closes the block """ then } type Injected { x: Int }"#
    let sdl = catalog(fieldDescription: injection).sdl()
    let expected = #"""
      type Thing {
        """
        closes the block \""" then } type Injected { x: Int }
        """
        id: ID!
      }
      """#
    #expect(sdl == expected + "\n")
    // The injected text stays inside the block string: exactly one `type` definition.
    #expect(sdl.components(separatedBy: "type ").count - 1 == 2)  // "type Thing" + the inert "type Injected" text
    #expect(!sdl.contains("\n}\ntype Injected"))
    // The kit's own lexer accepts the output and the payload survives as one token.
    let tokens = try GraphQLLexer.tokenize(sdl)
    let blocks = tokens.filter { $0.kind == .blockString }
    #expect(blocks.count == 1)
    #expect(blocks[0].text.contains(#"\""""#))
    #expect(try GraphQLStringDecoder.decode(blocks[0]).contains(injection))
  }

  @Test("a description ending in a quote needs no padding")
  func descriptionEndingInAQuote() throws {
    // The closing delimiter always follows a newline plus indent, so no run of three
    // quotes can form across that boundary. Confirmed by lexing, not by inspection.
    for text in ["ends in a quote\"", "ends in two\"\"", "\""] {
      let sdl = catalog(fieldDescription: text).sdl()
      let tokens = try GraphQLLexer.tokenize(sdl)
      let blocks = tokens.filter { $0.kind == .blockString }
      #expect(blocks.count == 1, "for \(text)")
      #expect(try GraphQLStringDecoder.decode(blocks[0]).hasSuffix(text), "for \(text)")
    }
  }

  @Test("a multi-line description with a delimiter on its own line is escaped")
  func multiLineDescriptionWithDelimiter() throws {
    let text = "first line\n\"\"\"\nlast line"
    let sdl = catalog(fieldDescription: text).sdl()
    #expect(sdl.contains("\n  \\\"\"\"\n"))
    let tokens = try GraphQLLexer.tokenize(sdl)
    let blocks = tokens.filter { $0.kind == .blockString }
    #expect(blocks.count == 1)
    #expect(try GraphQLStringDecoder.decode(blocks[0]).contains("\"\"\""))
  }

  @Test("a delimiter split across a line boundary is still escaped")
  func delimiterStraddlingALineBoundary() throws {
    // The replacement runs on the whole text before the newline split. A `""` at the end
    // of one line followed by `"` at the start of the next does NOT form a delimiter in
    // the output, because the newline separates them — the real risk this pins is that
    // the escape is applied per line, which would miss a `"""` inside one line entirely.
    let text = "a\"\"\"b\nc\"\"\"d"
    let sdl = catalog(fieldDescription: text).sdl()
    #expect(sdl.components(separatedBy: #"\""""#).count - 1 == 2)
    let tokens = try GraphQLLexer.tokenize(sdl)
    #expect(tokens.filter { $0.kind == .blockString }.count == 1)
  }

  @Test("the full-catalog goldens are unchanged by the escape")
  func escapeLeavesOrdinaryDescriptionsUntouched() {
    // Control: neither fixture carries a quote in any description, so both goldens must
    // be byte-identical to what the two golden tests above already assert.
    #expect(!FixtureCatalogs.gmail.sdl().contains("\\\"\"\""))
    #expect(!FixtureCatalogs.documents.sdl().contains("\\\"\"\""))
    #expect(FixtureCatalogs.gmail.sdl().contains("An RFC 3339 timestamp."))
    #expect(FixtureCatalogs.documents.sdl().contains("Spreadsheet major dimension."))
  }

  @Test("multi-line descriptions keep their line breaks inside the block string")
  func multiLineDescription() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      types: [GatewayNamedType(name: "S", kind: .scalar, description: "one\ntwo")]
    )
    #expect(catalog.sdl() == "\"\"\"\none\ntwo\n\"\"\"\nscalar S\n")
  }
}
