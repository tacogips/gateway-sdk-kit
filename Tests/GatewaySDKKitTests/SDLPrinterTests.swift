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
