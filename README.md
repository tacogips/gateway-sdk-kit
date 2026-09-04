# gateway-sdk-kit

Dependency-free Swift package holding the gateway-independent half of the tacogips gateway client SDKs: the neutral schema catalog model, SDL printing, regex schema search, the operation-to-GraphQL-document builder, the argv builder for command-style gateways, and the lexer-aware GraphQL variable inliner.

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
    )
  ],
  types: [
    GatewayNamedType(
      name: "ThreadConnection",
      kind: .object([GatewayField(name: "totalCount", type: .nonNull(.named("Int")))])
    )
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

### 5. Inline variables for gateways that take no variables map

```swift
let inliner = GraphQLVariableInliner(catalog: catalog)
try inliner.inline(
  document: "query Threads($accountId: ID!, $d: Direction = INBOUND) { threads(accountId: $accountId, direction: $d) { totalCount } }",
  variables: ["accountId": .string("acct-1")]
)
// query Threads { threads(accountId: "acct-1", direction: INBOUND) { totalCount } }
```

The rewrite validates the wrike rules (every declared variable used, every used
variable declared, no unknown supplied variable, required variables supplied or
defaulted, values type-checked, and every object key anywhere in a value a legal
GraphQL Name) and then splices the original string: the variable-definition
parenthesis is deleted and each `$var` token is replaced by its literal. Whitespace,
comments, strings and block strings are preserved byte for byte, and `$`-looking text
inside them is never touched. `GraphQLLexer` and `GraphQLLiteralRenderer` are public
for callers that need the pieces directly.

The object-key rule is inliner-only, and it is the one place this kit is stricter than
its own type check. The inliner splices keys straight into GraphQL source, where they
must be Names (`/^[_A-Za-z][_0-9A-Za-z]*$/`); a key like `page-size` would produce a
document the gateway cannot parse, so it throws `variableTypeMismatch` instead. The
document builder and the argv builder still carry arbitrary JSON keys unchanged — the
builder passes variables through as a GraphQL variables map and never renders a key,
and the argv builder JSON-encodes objects — so `validated for the builder` does not
imply `inlinable`.

```swift
// Fine for GatewayDocumentBuilder and GatewayArgvBuilder, rejected by the inliner:
["j": .object(["page-size": .int(50)])]
```

One semantic difference from real GraphQL variables is worth knowing: a declared, used,
nullable variable that is neither supplied nor defaulted inlines to an explicit `null`.

```swift
try inliner.inline(document: "query Q($a: Int) { f(a: $a) }", variables: [:])
// query Q { f(a: null) }
```

The rewrite is a token splice, so it can replace `$a` but cannot delete the surrounding
`a: $a` pair the way an omitted GraphQL variable would. For an argument that
distinguishes "absent" (leave unchanged) from `null` (clear) — a patch-style mutation,
say — supply a value or give the variable a default rather than relying on omission.

## Development

```bash
mise install
mise run build
mise run test
mise run lint
```
