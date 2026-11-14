# gateway-sdk-kit

Dependency-free Swift package holding the gateway-independent half of the tacogips gateway client SDKs: the neutral schema catalog model, SDL printing, regex schema search, the operation-to-GraphQL-document builder, the argv builder for command-style gateways, and the catalog-driven GraphQL runtime.

Consumed by wrike-gateway, google-analytics-gateway, apple-gateway, gmail-gateway, and google-documents-gateway through their `<Name>GatewaySDK` facades, and by riela's gateway add-ons.

See `design-docs/briefs/gateway-sdk-kit-2026-09-04.md` for the brief and `design-docs/gateway-sdk-kit-design-2026-09-04.md` for the pinned design.

## API tour

### 1. Load and validate a catalog

A catalog is `Codable`, so a facade usually ships it as JSON and decodes it once.
`validate()` returns an empty list for a healthy catalog; every facade should assert
that per tier.

```swift
import GatewaySDKKit

let catalog = try JSONDecoder().decode(GatewaySchemaCatalog.self, from: catalogJSON)
precondition(catalog.validate().isEmpty)

catalog.operation(named: "threads")          // GatewayOperation?
catalog.namedType("Thread")                  // GatewayNamedType?
catalog.operations(of: .mutation)            // [GatewayOperation]
```

Building one by hand looks like this:

```swift
let catalog = GatewaySchemaCatalog(
  provider: "gmail-gateway",
  tier: "reader",
  operations: [
    GatewayOperation(
      name: "threads",
      kind: .query,
      tier: "reader",
      arguments: [
        GatewayArgument(name: "accountId", type: .nonNull(.named("ID")), isRequired: true),
        GatewayArgument(name: "first", type: .named("Int"))
      ],
      result: .named("ThreadConnection"),
      summary: "List mail threads for an account."
    ),
    GatewayOperation(
      name: "labels",
      kind: .query,
      tier: "reader",
      arguments: [GatewayArgument(name: "accountId", type: .nonNull(.named("ID")), isRequired: true)],
      result: .named("Label"),
      summary: "List labels for an account."
    )
  ],
  types: [
    GatewayNamedType(
      name: "ThreadConnection",
      kind: .object([GatewayField(name: "totalCount", type: .nonNull(.named("Int")))])
    ),
    GatewayNamedType(name: "Label", kind: .object([GatewayField(name: "name", type: .named("String"))]))
  ]
)
```

`GatewayTypeRef` parses and prints the GraphQL spelling:

```swift
let ref = try GatewayTypeRef.parse("[Foo!]!")
ref.graphQLString    // "[Foo!]!"
ref.namedTypeName    // "Foo"
ref.isRequired       // true
ref.isList           // true
```

### 2. Print SDL and search the schema

```swift
print(catalog.sdl())                                  // scalars, enums, inputs, objects, Query, Mutation, Command
catalog.sdlFragment(for: .query, name: "threads")     // exactly one definition, valid on its own

let search = GatewaySchemaSearch(catalog: catalog)
let matches = try search.search(
  "thread",
  options: .init(kinds: [.query, .object], includeReferencedTypes: true, limit: 10)
)
matches.first?.matchedOn   // ["name", "summary"]
matches.first?.sdl         // the SDL fragment of that definition
```

Exact whole-name matches sort first, then kind order (query, mutation, command,
object, inputObject, enumeration, scalar), then name. `includeReferencedTypes` appends
the argument types (transitively through input objects) and the result type plus one
level of its fields, each labelled `referenced-by:<operation>`.

Schema-search patterns use a deliberately conservative, portable regex subset. A
pattern may be at most 256 UTF-8 bytes and may contain at most one unescaped optional
quantifier (`?`). Literals, Unicode text, empty patterns, anchors, dot,
character classes, unquantified capturing groups, ordinary escapes, and depth-zero
alternation are supported. Use `^threads$|^sendMessage$` for alternatives; an escaped
`\\|` or `|` inside a character class is a literal pipe. Grouped alternation,
unbounded `*` or `+`, quantified groups, repeated or counted quantifiers, backreferences, and every `(?`
extension (lookaround, options, non-capturing, or named groups) are excluded. Rejected
policy patterns and malformed patterns use the stable `GatewaySDKError.invalidPattern`
error. This fixed subset bounds shared SDK and CLI search work; it is not a general
safety classification for Swift Regex.

### 3. Build a document or an argv array

```swift
let built = try GatewayDocumentBuilder(catalog: catalog).build(
  GatewayOperationRequest(
    operation: "threads",
    variables: ["accountId": .string("acct-1"), "first": .int(20)]
  )
)
print(built.document)
// query Threads($accountId: ID!, $first: Int) {
//   threads(accountId: $accountId, first: $first) {
//     totalCount
//     pageInfo { hasNextPage endCursor }
//     edges { cursor node { id subject messages { id snippet direction } } }
//   }
// }
```

Only supplied variables are declared and passed; catalog defaults are never injected,
so the gateway keeps applying its own. The default selection walks the result type to
depth 3, stops at a type already on the current path, and skips fields that take
required arguments. Choose a different selection with `.fields([...])` dot paths or a
verbatim `.raw("{ ... }")` set:

```swift
GatewayOperationRequest(operation: "threads", selection: .fields(["totalCount", "edges.node.subject"]))
GatewayOperationRequest(operation: "threads", selection: .raw("{ totalCount }"))
```

Command catalogs build argv instead:

```swift
try GatewayArgvBuilder.build(
  GatewayOperationRequest(
    operation: "files list",
    variables: ["page-size": .int(20), "fields": .array([.string("id"), .string("name")])]
  ),
  catalog: commandCatalog
)
// ["files", "list", "--page-size", "20", "--fields", "id", "--fields", "name"]
```

`Boolean true` becomes a bare flag, `false` is omitted, lists repeat the flag, and
objects render as compact sorted-key JSON.

### 4. Conform a facade and invoke

Implement the four required members; `invoke`, `schemaSDL`, and `searchSchema` have
default implementations.

```swift
struct GmailGatewaySDK: GatewaySDK {
  let provider = "gmail-gateway"
  let tier = "reader"
  let catalog: GatewaySchemaCatalog

  func execute(
    document: String,
    variables: [String: GatewayJSONValue],
    environment: [String: String]
  ) async -> GatewayEnvelope {
    let (stdout, exitCode) = await runTheGateway(document, variables, environment)
    return GatewayEnvelope(parsingCLIOutput: stdout, exitCode: exitCode)
  }
}

let envelope = await sdk.invoke(
  GatewayOperationRequest(operation: "threads", variables: ["accountId": .string("acct-1")]),
  environment: ["GMAIL_TOKEN": token]
)
envelope.data      // GatewayJSONValue?
envelope.errors    // [GatewayEnvelopeError]
envelope.requestId // String?
```

`invoke` routes commands through `GatewayArgvBuilder` and hands `execute` a compact
JSON-encoded argv array in `document`. A builder error never throws out of `invoke`:
it comes back as `GatewayEnvelope.failure(error, exitCode: 2)`.

`GatewayEnvelope(parsingCLIOutput:exitCode:)` understands both shapes the gateways
print today — `{data, errors, extensions: {requestId}}` and `{ok, data, error}` — and
turns anything else into one error carrying the raw text.

Emit one shape or the other, never a mixture: a payload carrying markers from both, such
as `errors` alongside `ok`, matches neither and degrades to a raw-text error. Facade
authors control the producers, so this costs nothing to observe and keeps a failed call
from ever being reported as an empty success.

### 5. Run documents with the catalog-driven runtime

```swift
let resolvers: [String: GatewayGraphQLRuntime.Resolver] = [
  "threads": { _, _ in .object(["totalCount": .int(1)]) },
  "labels": { _, _ in .object(["name": .string("Inbox")]) }
]
let runtime = try GatewayGraphQLRuntime(catalog: catalog, resolvers: resolvers)
let envelope = await runtime.execute(
  document: #"query { threads(accountId: "a1") { totalCount } }"#,
  context: GatewayResolverContext(requestId: "req-1")
)
// envelope.data, envelope.errors, envelope.requestId, envelope.rawOutput
```

Pass a tier-limited catalog as `authorized:` to fail closed with `CAPABILITY_DENIED`
before any resolver runs. Exit codes are `0` for success, `1` for resolver or capability
errors, and `2` for syntax or validation errors. Fragments, directives, subscriptions,
multiple operations, and introspection (including `__typename`) are deliberately
rejected. Documents are limited to 256 KiB, 20,000 tokens, 1,000 selections and bounded
input/result trees; queries run no more than eight resolvers concurrently.

## Development

```bash
mise install
mise run build
mise run test
mise run lint
```

Resolver errors may expose optional `GatewayErrorDiagnostics` containing only bounded
`httpStatus` (100–599) and `providerErrorCode` (0–99999) integers. The runtime carries
these directly to the matching error path and serializes them under that error's
`extensions`. Existing conformers need no change; the default is `nil`. Unknown
metadata and invalid numeric values are omitted, and CLI envelope parsing and
Codable round trips preserve the typed diagnostics.
