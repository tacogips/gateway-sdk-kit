# Design: catalog-driven GraphQL runtime, inliner removal (2026-09-04)

Brief: `design-docs/briefs/gateway-sdk-kit-runtime-2026-09-04.md` (normative).
Master design: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md` section 2.6.
One feature; no fanout. Baseline verified green (207 tests, 0 lint violations) at 8cf47d2.

Workflow traceability: `codex-design-and-implement-review-loop-session-88`, intake
communication `comm-001033`, design-update input `comm-001034`, mode
`issue-resolution`, adversarial review required because authorization gates destructive
resolvers and the parser/coercion/projection path handles untrusted values. The accepted
work package is exactly the parser, validator, fail-closed authorization, resolver
runtime, projection/envelope surface, hostile-input coverage, obsolete inliner/renderer
removal, and user-facing documentation described here. It adds no networking, CLI,
credentials, gateway-specific behavior, dependency, fragment/directive/subscription/
introspection support, or second feature.

The Codex-agent references guide this repository workflow only; no Cursor CLI behavior
or agent adapter is part of the production package. The brief's older `main` handoff is
intentionally superseded by the accepted intake constraint to finish fully committed
and clean on `feat/graphql-runtime`, without pushing.

## 1. File layout

New files, all in the existing `GatewaySDKKit` target (no Package.swift target change):

| File | Contents | Est. size |
| --- | --- | --- |
| `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLDocument.swift` | AST: `GatewayGraphQLDocument`, nested `VariableDefinition`, `Selection`, `Argument`; top-level `GraphQLValue` | ~150 |
| `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLLimits.swift` | internal fixed phase-0b resource budgets shared by parsing, validation, coercion, execution, and projection | ~100 |
| `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLParser.swift` | recursive-descent parser over `GraphQLLexer` tokens, line/column mapping, and the internal shared string/block-string decoder | ~450 |
| `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLValidator.swift` | `GatewayGraphQLValidator`, `ValidatedOperation`, argument/variable coercion | ~500 |
| `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLRuntime.swift` | `GatewayResolverContext`, `GatewayResolverError`, `GatewayGraphQLRuntime`, envelope assembly | ~350 |
| `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLProjection.swift` | internal projection of resolver results onto selection sets | ~150 |

Deleted: `Sources/GatewaySDKKit/GraphQLVariableInliner.swift`,
`Sources/GatewaySDKKit/GraphQLLiteralRenderer.swift` (Sources-side, only the inliner uses
it; the runtime coerces literals *into* `GatewayJSONValue`, never renders them out, so
the brief's keep-if-reused condition is not met),
`Tests/GatewaySDKKitTests/VariableInlinerTests.swift`.

Kept: `GraphQLLexer` (+ its tests) — the parser consumes its tokens. Its public types
and signature do not change; its thrown error contract becomes positioned `.syntax`,
and its two inliner-specific documentation comments are rewritten to describe
source-preserving token ranges and parser-visible comments generically.

Doc/comment touch-ups: README line 3 and section 5, `AGENTS.md` line 13 overview
sentence, `Package.swift` header comment, the inliner-specific overview in
`GatewaySDKError.swift`, both affected comments in `GatewayVariableTypeCheck.swift`,
the two affected comments in `GraphQLLexer.swift`, and `HostileCatalogTests` (drop the
renderer and inliner tests, add runtime/validator equivalents — see §8).

## 2. Error surface (additive `GatewaySDKError` cases)

```swift
case syntax(message: String, line: Int, column: Int)          // parser stage
case validation(code: String, message: String, path: [String]) // validator stage
```

Both get `description` arms (`"syntax error at L:C: message"`, `"CODE at a.b.c: message"`).
Adding cases to the public enum breaks downstream exhaustive switches; the operator
waived backward compatibility and the gateways are rewritten against this surface.
`GraphQLLexer.tokenize` keeps its public signature but every lexical failure now throws
`.syntax` directly with a structured 1-based line and column. This intentionally changes
the thrown case under the operator's compatibility waiver; the parser propagates it
unchanged. Parser-level rejections (fragments, directives, subscriptions, multiple
operations, introspection, and structural errors) also throw `.syntax`.

Line/column are 1-based. Lexer and parser compute them only on failure by walking from
the source start to the failing index, counting GraphQL line terminators (`\n`, `\r`,
`\r\n` as one). Unexpected characters use their own index; a missing variable name uses
the `$`; unterminated strings/block strings use their opening delimiter; malformed
fraction/exponent errors use the first missing-digit position, including one-past-end at
EOF. One O(n) walk per failed parse, zero cost on success.

## 3. AST and parser

```swift
public struct GatewayGraphQLDocument: Sendable, Equatable {
  public enum OperationType: String, Sendable, Equatable { case query, mutation }
  public struct VariableDefinition: Sendable, Equatable {
    public var name: String
    public var type: GatewayTypeRef
    public var defaultValue: GraphQLValue?
  }
  public struct Argument: Sendable, Equatable {
    public var name: String
    public var value: GraphQLValue
  }
  public struct Selection: Sendable, Equatable {
    public var alias: String?
    public var name: String
    public var arguments: [Argument]
    public var selectionSet: [Selection]
    public var responseKey: String { alias ?? name }
  }
  public var operationType: OperationType
  public var name: String?
  public var variableDefinitions: [VariableDefinition]
  public var selectionSet: [Selection]
}

public indirect enum GraphQLValue: Sendable, Equatable {
  case int(Int64), float(Double), string(String), bool(Bool), null
  case enumValue(String), variable(String)
  case list([GraphQLValue]), object([(name: String, value: GraphQLValue)])
}

public enum GatewayGraphQLParser {
  public static func parse(_ document: String) throws -> GatewayGraphQLDocument
}
```

(`object` keeps pair order so duplicate keys are detectable; duplicate keys in one
object literal are a `.syntax` error. Types nested under the document avoid colliding
with the existing `GatewaySelection`. All memberwise inits public.)

Grammar accepted (exactly the brief's subset):
- `{ selections }` shorthand (no name, no variable definitions), or
  `query|mutation [Name] [( varDefs )] { selections }`.
- Variable definitions `$name: TypeSpelling [= defaultLiteral]`; the type is parsed
  token-wise into `GatewayTypeRef` directly (name/`[`/`]`/`!` tokens), not via
  `GatewayTypeRef.parse` on a reassembled string, so errors keep positions. Default
  values are const literals (a `variable` inside a default is `.syntax`). A duplicate
  variable name is `.syntax` at the second `$name` token.
- Field: `[alias:] name [( args )] [{ selections }]`; arguments are literals or
  variables; a duplicate argument name in one field is `.syntax` at the second name;
  nesting is bounded by the resource policy below; comments and commas are ignored
  (lexer already skips commas and emits comments; the parser filters comment tokens).
- Literals: int (Int64; overflow is `.syntax`), float, string (escape decoding: the
  spec's named escapes, `\uXXXX` with surrogate-pair combination; a lone surrogate or
  unknown escape is `.syntax`), block string (strip `"""`, spec common-indent
  removal, leading/trailing blank-line strip, `\"""` unescape), `true|false|null`,
  bare-name enum values, lists, input objects with Name keys.

Rejected with `.syntax(message:line:column:)`, message naming the construct:
- `fragment` definitions and `...` (spread and inline fragments) — the lexer already
  emits `...` as one punctuator.
- `@` directives anywhere.
- `subscription` operations.
- A second operation definition after the first (`multiple operations`).
- Root or nested fields named `__schema`, `__type`, or `__typename` (checked at parse
  time so introspection is rejected uniformly, before validation).
- Structural errors: unexpected/missing token, unterminated selection set, empty
  selection set `{}`, empty variable-definition parens, duplicate variable declarations,
  duplicate field arguments, trailing tokens after the operation.

The parser is a cursor over the comment-filtered token array; positions come from each
token's `range` against the retained source string.

String and block-string decoding is owned by an internal `GraphQLStringDecoder` in the
parser file. The parser supplies the source-position context and converts decoder
failures into `.syntax`; the decoder does not expose a new public API. Existing
`SDLPrinterTests` block-string safety assertions move from
`GraphQLVariableInliner.decodeStringToken` to this shared decoder before the inliner is
deleted. This keeps those injection-regression tests compiling and exercises the same
decoder used by runtime parsing.

### Fixed resource limits and fail-closed behavior

Phase 0b uses fixed internal limits, not caller-configurable knobs. They apply equally
on macOS and Linux and are centralized in internal `GatewayGraphQLLimits` so parser,
validator, runtime, projection, and tests cannot drift:

| Limit | Maximum | Counting rule |
| --- | ---: | --- |
| UTF-8 document size | 262,144 bytes | `document.utf8.count`, checked before lexing |
| lexer tokens | 20,000 | every emitted token including comments; ignored commas and any synthetic EOF do not count |
| recursive structural depth | 32 | root field/value/result is depth 1; each nested selection, list/object container, list type wrapper, projected object/list, or input-value container adds 1 |
| selections | 1,000 | all root and nested `Selection` nodes in one document |
| root fields | 64 | root selections; aliases do not merge fields |
| list/object entries | 1,000 | direct members of each literal, supplied/defaulted JSON container, or resolver-result container |
| input value nodes | 10,000 | aggregate scalar/null/container nodes across document literals, supplied variables, and materialized defaults for one request |
| resolver result nodes | 10,000 | aggregate scalar/null/container nodes inspected/projected for one root resolver result |
| concurrent query resolvers | 8 | live resolver tasks; mutations remain exactly one |

The document byte check precedes lexing. The parser invokes a limit-aware internal lexer
entry point that stops before retaining token 20,001; the existing public lexer entry
point remains source-compatible. Parser counters reject the token that would create
depth 33, selection 1,001, root field 65, container entry 1,001, or input node 10,001.
These text-document failures are positioned `.syntax`; document-size overflow uses
line 1, column 1, token overflow uses the 20,001st token, and structural overflows use
the opening/name/value token that crosses the limit. Runtime mapping is stable code
`SYNTAX`, no path, `data: null`, exit 2, and zero resolver calls. The syntax message is
`"resource limit exceeded: <limitName> maximum <N>"`, with limit names
`documentBytes`, `tokens`, `depth`, `selections`, `rootFields`, `containerEntries`, or
`inputValueNodes`.

Because callers can construct the public AST and variables directly, validation begins
with an iterative budget walk before its recursive semantic passes. A direct AST,
supplied variable, or materialized default over budget throws stable validation code
`RESOURCE_LIMIT`: empty path for document-, variable-, or aggregate-node limits, and
the owning response-key path for selection/argument/container limits. The runtime maps
it to `data: null`, exit 2, and zero resolver calls. The walk does not include attacker-
controlled values in its message; it uses the same stable
`"resource limit exceeded: <limitName> maximum <N>"` format.

Projection uses an iterative budget/non-finite preflight before recursive projection.
An oversized or over-depth resolver result becomes `RESOLVER_SHAPE` at the deepest
known response-key path, nulls that root field, and yields exit 1; the resolver has
already run, so the zero-call guarantee applies only to document/input rejection.
Its message is `"resolver result exceeds <limitName> maximum <N>"`. At-limit inputs are
accepted; the first value above each maximum is rejected.

## 4. Validator

```swift
public struct GatewayGraphQLValidator: Sendable {
  public init(catalog: GatewaySchemaCatalog)
  public func validate(
    _ document: GatewayGraphQLDocument,
    variables: [String: GatewayJSONValue] = [:]
  ) throws -> ValidatedOperation
}

public struct ValidatedOperation: Sendable, Equatable {
  public struct RootField: Sendable, Equatable {
    public var responseKey: String          // alias ?? name
    public var name: String                 // catalog operation name
    public var arguments: [String: GatewayJSONValue]  // coerced
    public var selectionSet: [GatewayGraphQLDocument.Selection]
    public var operation: GatewayOperation  // catalog entry (result type for projection)
  }
  public var operationType: GatewayGraphQLDocument.OperationType
  public var name: String?
  public var rootFields: [RootField]        // document order
}
```

A convenience `validate(documentText:variables:)` is *not* added; the runtime parses
then validates, and tests exercise each stage directly.

Every failure throws `.validation(code:message:path:)`. `path` is the response-key path
from the root to the field owning the error (empty for operation/variable-level errors;
the message names the variable or argument). First error wins (throwing validator, per
the brief's `throws` signature).

Code-by-code triggers (the 12 stable codes, pinned):

| Code | Trigger |
| --- | --- |
| `UNKNOWN_FIELD` | root field not found among catalog operations of the document's kind (a mutation name under `query`, a command name, or a truly unknown name all land here) |
| `MULTIPLE_MUTATIONS` | a `mutation` document with more than one root field |
| `DUPLICATE_ALIAS` | the same response key (alias or name) appearing twice in any one selection set, at any depth including the root |
| `UNKNOWN_ARGUMENT` | argument name not declared on the root operation (first-wins dictionary over declared names, per the hostile-catalog convention) |
| `MISSING_ARGUMENT` | required argument (`isRequired \|\| type.isRequired`) with no catalog default, not supplied — including "fed by a nullable variable that has no value and no default" (omission semantics, see below) |
| `ARGUMENT_TYPE` | a coerced argument value failing `GatewayVariableTypeCheck.matches` against the declared argument type; also an enum literal whose target type is not an enum of which it is a member, an unknown input-object key, or an object-literal value for a non-input type |
| `UNDECLARED_VARIABLE` | `$x` used anywhere in an argument value (including inside list/object literals) without a matching declaration |
| `UNUSED_VARIABLE` | a declared variable never used anywhere in the document |
| `UNKNOWN_VARIABLE` | a key in the supplied `variables` map that matches no declaration |
| `MISSING_VARIABLE` | a declared variable with outer non-null type, no supplied value, no default |
| `VARIABLE_TYPE` | (a) a supplied value failing the type check against the declared variable type, or (b) a declared variable type that does not exactly equal the argument type it feeds, after stripping the variable's outer non-null when the argument type is optional (`T!` may feed `T`; `T` may NOT feed `T!`) |
| `INVALID_SELECTION` | nested field unknown on its parent object type; any argument list on a nested field; a selection set on a leaf (scalar, enum, `JSON`, custom scalar); an object-typed field with no (or empty) selection set; a root field whose result type is composite but has no selection set |

Parser-produced documents cannot contain duplicate variable declarations or duplicate
arguments because both are positioned `.syntax` errors. As defense for callers that
construct the public AST directly, the validator rejects them before building any map:
`DUPLICATE_VARIABLE` with an empty path for a repeated variable definition, and
`DUPLICATE_ARGUMENT` at the owning response-key path for a repeated field argument.
These two defensive codes supplement rather than replace the 12 accepted request codes.

Validation walks the selection tree with the catalog result types (`GatewayField` /
`GatewayOperation.result`). Root-field arguments use the rules above. Any argument list
on a nested selection is rejected before variable bookkeeping with
`INVALID_SELECTION`, at that nested response-key path and with a message that nested
field arguments are unsupported. The parser still represents the syntax, but the
runtime cannot silently accept behavior its root-only resolver signature cannot honor.
Nested field names, aliases, and selection shape continue to validate recursively.

### Coercion rules (validator output)

- Variable substitution happens during coercion; a variable's effective value is:
  supplied value, else its declared default, else *absent*.
- An argument fed by an absent variable (or simply not written) is **omitted** from the
  coerced map, then the catalog argument `defaultValue` is applied if present, then
  `MISSING_ARGUMENT` fires if the argument is required and still absent. An explicit
  `null` (literal or supplied variable value) is a present value, is never replaced by a
  default, and satisfies "supplied" only for nullable arguments (the type check rejects
  null against non-null).
- Enum literals become `.string(name)` only when the target named type is an enum
  containing that name; otherwise `ARGUMENT_TYPE`. Enum values arriving as strings via
  variables are accepted (matches `GatewayVariableTypeCheck`, which is the wire rule).
- Input objects: unknown keys are `ARGUMENT_TYPE` (the reused check already rejects
  them); declared-but-missing keys get the input field's `defaultValue` when present;
  required input fields missing after defaults are `ARGUMENT_TYPE` (via the reused
  check). Output therefore contains only declared keys.
- Coercion materializes a resolver-visible value recursively against its target type
  after `GatewayVariableTypeCheck.matches` establishes admissibility. Non-null unwraps
  and recurses; null remains null only for nullable types; an array maps each element;
  a non-array accepted for a list becomes a one-element `.array`; an `Int` accepted for
  `Float` becomes `.double`; enum strings remain strings; `JSON` and custom scalars pass
  through. Input-object members are materialized against declared field types, omitted
  defaults are materialized by the same routine, and nested input-object/list defaults
  recurse. Catalog argument defaults and variable defaults also use this routine. The
  result includes only declared supplied/defaulted keys.
- The materialized per-argument value is checked again with
  `GatewayVariableTypeCheck.matches` against the argument type. The check also rejects
  non-finite doubles anywhere in the value, keeping `jsonString` serialization total.

## 5. Runtime

```swift
public struct GatewayResolverContext: Sendable {
  public var environment: [String: String]
  public var requestId: String
  public var userInfo: [String: GatewayJSONValue]
  public init(environment: [String: String] = [:], requestId: String = "",
              userInfo: [String: GatewayJSONValue] = [:])
}

public protocol GatewayResolverError: Error {
  var code: String { get }
  var message: String { get }
}

public struct GatewayGraphQLRuntime: Sendable {
  public typealias Resolver = @Sendable (
    _ arguments: [String: GatewayJSONValue],
    _ context: GatewayResolverContext
  ) async throws -> GatewayJSONValue

  public init(catalog: GatewaySchemaCatalog,
              authorized: GatewaySchemaCatalog? = nil,
              resolvers: [String: Resolver]) throws
  public static func check(catalog: GatewaySchemaCatalog,
                           resolvers: [String: Resolver]) -> [String]  // problem list
  public func execute(document: String,
                      variables: [String: GatewayJSONValue] = [:],
                      context: GatewayResolverContext) async -> GatewayEnvelope
  public func printedSchema() -> String   // authorized (or catalog) SDL via catalog.sdl()
}
```

- `init` runs `check` and throws `GatewaySDKError.validation` on the first problem:
  code `"MISSING_RESOLVER"` for a catalog query/mutation root field with no resolver,
  code `"UNKNOWN_RESOLVER"` for a resolver key matching no catalog query/mutation
  (catches typos; command-kind operations need no resolver and never appear in either
  list). These are composition-time codes, deliberately outside the 12 request-time
  validator codes. `check` returns all problems as human-readable strings for adopters
  that want the full list.
- `authorized` defaults to `catalog` when nil. Stored as `catalog`, `authorizedCatalog`,
  `resolvers`.

### Execute pipeline

1. **Parse.** Enforce text resource limits, then parse. Every resource-, lexer-, or
   parser-originated failure is `.syntax` with structured line/column and becomes an envelope with `data` nil, one error
   `{message: error.description, code: "SYNTAX"}`, and `exitCode` 2.
2. **Validate.** Iteratively enforce direct-AST/variable/default budgets before
   semantic recursion. A thrown `.validation(code:message:path:)` → envelope error
   carrying that code and path, `data` nil, `exitCode` 2.
3. **Authorize.** For each root field in document order: allowed iff
   `authorizedCatalog` contains an operation with that name and the document's kind.
   If *any* root field is denied, **no resolver runs at all** (the brief's "without
   calling any resolver" is read literally as whole-request denial): envelope has
   `data` nil, one `CAPABILITY_DENIED` error per denied field with
   `path: [responseKey]` and message
   `"root field '<name>' is not available to tier '<authorizedCatalog.tier>'"`,
   `exitCode` 1 (authorization is an execution-stage refusal, not syntax/validation,
   so it is 1 not 2).
4. **Resolve.** Queries use a sliding-window `withTaskGroup` keyed by document index.
   Seed at most eight tasks; whenever one completes, store its indexed outcome and add
   the next field, keeping at most eight resolver calls live. Results are assembled by
   index so `data` membership and error order are deterministic document order
   regardless of completion order. Mutation: exactly one root field (validator
   enforced), awaited alone. Per field:
   - resolver returns a value → project (step 5);
   - resolver throws `GatewayResolverError` → error `{code: e.code, message:
     e.message, path: [responseKey]}`, `data[responseKey] = null`;
   - resolver throws anything else → error `{code: "RESOLVER_ERROR", message:
     "resolver failed", path: [responseKey]}`, `data[responseKey] = null`. The runtime
     discards the underlying description; it has no logging channel and never places
     that text in the envelope or `rawOutput`.
   Partial results are kept: a multi-field query returns successful fields in `data`
   alongside the errors, `exitCode` 1.
5. **Project** (internal `GatewayGraphQLProjection`). Inputs: resolver value, the
   validated selection set, the field's declared result `GatewayTypeRef`, catalog.
   - Leaf result (scalar/enum/`JSON`/custom scalar; selection set empty by
     validation): the value passes through unchanged.
   - Declared list type: value must be `.array` (or `.null`); elements map recursively
     against the element type. Nesting (`[[T]]`) recurses per list wrapper.
   - Declared object type: value must be `.object` or `.null`. `null` propagates as
     `null` without recursion. For an object, output = ordered copy keyed by each
     selection's `responseKey`, value = recursive projection of
     `object[selection.name]`; an absent key projects to `null`. Nested arguments are
     absent because validation rejects them before resolver dispatch.
   - Shape breaches — non-array where a list is declared, non-object where an object
     is declared, a non-finite double, or a depth/container/node resource overflow
     anywhere in the resolver result (checked once iteratively up front so `rawOutput`
     serialization and recursive projection are bounded) — produce one error
     `{code: "RESOLVER_SHAPE", path: <response-key path to the breach>}` and the whole
     root field becomes `data[responseKey] = null` (no partial subtrees), `exitCode` 1.
6. **Envelope.** `data` = `.object` of per-root-field results (`GatewayJSONValue`
   objects are dictionaries; the pinned sorted-key `jsonString` gives deterministic
   output). `errors` in document order. `requestId` from the context. `exitCode`: 0 if
   no errors, 2 for steps 1–2, 1 otherwise. `rawOutput` = compact
   `try? GatewayJSONValue.object([...]).jsonString()` of
   `{data, errors, extensions: {requestId}}` — `errors` is always present and is an
   empty array on success; `data` is always present (JSON `null` when nil), and
   `extensions.requestId` is always present. Serialization cannot throw
   (non-finite doubles are rejected in steps 4–5); the `try?` fallback is `""`.
   Round-trip property: `GatewayEnvelope(parsingCLIOutput: env.rawOutput, exitCode:
   env.exitCode)` reproduces `data`, `errors` (message/code/path), and `requestId`.

### Concurrency and Sendability

All new public types are `Sendable` (value types over `Sendable` members; the resolver
table is `[String: Resolver]` of `@Sendable` closures). The task group's child results
are `(Int, FieldOutcome)` value pairs; no shared mutable state, no `@unchecked`.
Swift 6 strict concurrency, Foundation only, Linux-clean (no `Synchronization` import;
test recorders use an actor).

## 6. Data flow

```
document text ──text budgets + parse──▶ GatewayGraphQLDocument
──iterative AST/input budgets + validate(catalog, variables)──▶
ValidatedOperation (coerced args per root field) ──authorize(authorizedCatalog)──▶
allowed root fields ──bounded TaskGroup / single mutation──▶ GatewayJSONValue
──result budgets + project(selection, result type)──▶ data + errors ──▶
GatewayEnvelope {data, errors, requestId, exitCode, rawOutput}
```

State: the runtime is immutable after `init`; per-call state lives on the stack of
`execute`. No caches, no global state.

## 7. Compatibility / security

- Existing public API untouched except: deletions (inliner, renderer) and additive
  `GatewaySDKError` cases. Catalog model, SDL printer, search, builders, `GatewaySDK`,
  `GatewayEnvelope` unchanged.
- Authorization is deny-by-default against the `authorized` subset and fails closed:
  denial short-circuits before any resolver, so no side effect can occur for a denied
  request, and the message names the tier (not "unknown field") to keep the
  full-catalog/subset distinction honest. Errors never echo supplied variable values,
  only names, types, and paths.
- Resolver failures are client-visible only when the adopter deliberately throws a
  `GatewayResolverError`; its `code` and `message` are the adopter's responsibility to
  redact. All other thrown errors use the stable `RESOLVER_ERROR` / `"resolver failed"`
  surface, preventing provider, environment, request, or credential text from leaking.
- Fixed byte, token, depth, selection, root-field, container, and node budgets reject
  hostile input before resolver dispatch. Query fanout is capped at eight live calls;
  the 64-root-field maximum bounds total calls while indexed assembly preserves output
  order.
- No new dependencies, products, targets; the package stays credential- and
  transport-free.

## 8. Test strategy (swift-testing; every file < 1000 lines)

New fixture `Tests/GatewaySDKKitTests/Fixtures/runtime-catalog.json` (loaded through the
existing `FixtureCatalogs.load`), gmail-like per the brief: tier `sender` full catalog with
`threads(input: ThreadSearchInput!): ThreadConnection!` (connection object graph),
`labels(accountId: ID!): [Label!]!`, mutation `sendMessage(input: SendMessageInput!):
SendMessagePayload!` at tier `sender`, plus `Direction` enum, `DateTime` scalar,
`ThreadSearchInput` input object (required + defaulted + enum fields). The existing
`gmail-catalog.json` stays untouched so current tests keep their pins. An
`authorizedReader` subset (operations minus `sendMessage`, `tier: "reader"`) is derived
in-test for CAPABILITY_DENIED.

- `GraphQLParserTests.swift`: every supported construct (shorthand, named ops,
  variable defs with scalar/list/object defaults, all literal kinds incl. negative
  numbers, escapes, surrogate pairs, block-string dedent, aliases, comments, commas,
  BOM, nesting); every rejection with exact line/column asserts (fragment definition,
  `...` spread, inline fragment, `@directive`, `subscription`, second operation,
  `__schema`, `__type`, `__typename` at root and nested, empty selection set,
  unterminated brace, trailing garbage, Int64 overflow, bad escape, duplicate
  object-literal key, duplicate variable declaration, duplicate root argument, duplicate
  nested argument); lexer-originated failures through `parse` (unexpected character,
  missing variable name, malformed fraction/exponent, unterminated string, unterminated
  block string), each asserting `.syntax` and exact line/column. Resource boundaries
  use generated valid documents immediately below, exactly at, and one above 262,144
  UTF-8 bytes, 20,000 tokens, depth 32, 1,000 selections, 64 root fields, 1,000 direct
  literal entries, and 10,000 literal value nodes; below/at-limit parses succeed and
  the first over-limit token fails with positioned `.syntax`.
- `GraphQLValidatorTests.swift`: for each of the 12 codes one failing and one passing
  case; variable default application; catalog argument and input-field default
  application; explicit-null-is-not-omission; enum literal vs quoted string vs unknown
  member; input-object unknown key; nested arguments rejected as `INVALID_SELECTION`
  before variable bookkeeping; the `T!`→`T` strip
  matrix (`T!`→`T` ok, `T`→`T` ok, `T`→`T!` VARIABLE_TYPE, `[T]!`→`[T]` ok,
  `[T!]`→`[T]` VARIABLE_TYPE); variables used inside list/object literals count as
  used; coerced output shape (only declared keys, enums as strings, singleton-to-list
  arrays, Int-to-Float conversion, recursive input/default materialization, document
  order of root fields); direct-AST duplicate variable and argument defenses asserting
  `DUPLICATE_VARIABLE` and `DUPLICATE_ARGUMENT`; iterative direct-AST/supplied-variable
  resource checks immediately below, exactly at, and one above depth, selection,
  root-field, container, and 10,000-node limits, asserting `RESOURCE_LIMIT`, path, and
  that semantic recursion does not start before preflight passes.
- `GraphQLRuntimeTests.swift`: actor-based recording resolvers asserting received
  arguments and call counts. Literal-only and variable-fed execution; concurrent
  multi-field query with one `GatewayResolverError` conformer → partial data + that
  code + exit 1 + deterministic error order; non-conforming error with a secret-bearing
  description → exact `RESOLVER_ERROR` / `"resolver failed"`, with neither the envelope
  nor `rawOutput` containing the secret; duplicate variable/argument documents →
  positioned SYNTAX, exit 2, zero resolver calls;
  each document/input resource rejection → exact code/path/exit 2 and zero resolver
  calls; queries with 7, 8, and 9 root fields use a recorder/barrier to prove no more
  than eight calls are simultaneously active while data and errors remain in document
  order;
  mutation runs alone and MULTIPLE_MUTATIONS is exit 2; CAPABILITY_DENIED: denied
  mutation and denied-query-beside-allowed-query both record **zero** resolver calls,
  message contains field name and `authorized.tier`, exit 1; projection: aliases,
  duplicate aliasing of one field twice under different keys, list mapping, missing
  key → null, null object propagation, RESOLVER_SHAPE for scalar-where-object,
  object-where-list, and non-finite double; envelope matrix (0 / 1 / 2) and rawOutput:
  compact, sorted keys, `extensions.requestId`, `errors: []` on success, and the
  `parsingCLIOutput` round-trip; `printedSchema() == authorized.sdl()`; `init` throws
  MISSING_RESOLVER / UNKNOWN_RESOLVER and `check` lists both; hostile duplicated
  catalog (port the two deleted HostileCatalogTests cases to the validator/runtime:
  duplicate operation and input-field names must degrade to thrown errors, never trap).
- `SDLPrinterTests.swift`: preserve the existing block-string delimiter/injection
  coverage, but decode valid lexer tokens through internal `GraphQLStringDecoder`
  instead of the deleted inliner helper.
- Deleted: `VariableInlinerTests.swift`; `HostileCatalogTests` loses its renderer and
  inliner tests (replaced as above). `GraphQLLexerTests` updates lexer-failure
  expectations from `.malformedDocument` offsets to exact `.syntax` line/column.

## 9. Rollout

Single branch `feat/graphql-runtime`, incremental commits as work lands (error cases →
AST/parser → validator → runtime/projection → deletions → docs), no push, no tag, no
AI attribution in messages. gmail-gateway adopts next; the README adopter example is
the contract demo. The implementation and review handoff must record these exact gates:

```bash
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gateway-sdk-kit-worktrees/runtime && swift build && swift test && swiftlint'
wc -l Sources/GatewaySDKKit/*.swift Sources/GatewaySDKKit/GraphQL/*.swift Tests/GatewaySDKKitTests/*.swift
rg -n -i 'inliner|GraphQLVariableInliner|GraphQLLiteralRenderer' Sources Tests README.md AGENTS.md Package.swift
git diff --check
git diff --cached --check
git status --porcelain
```

Every non-generated Swift file must remain below 1000 lines. The stale-reference search
must return no active source, test, README, agent-guide, or package-manifest reference.
The final status must be empty after the authorized commit; push remains unauthorized.

## 10. Decisions log (traceable)

1. Renderer deleted — Sources-side use is inliner-only (GraphQLVariableInliner.swift:395);
   runtime coerces JSON-ward. Brief's keep-if-reused condition unmet.
2. Lexer failures throw `.syntax` with 1-based line/column and the parser propagates
   them — the operator's compatibility waiver permits correcting the old error case.
3. Whole-request denial on any CAPABILITY_DENIED — literal reading of "without calling
   any resolver"; fails closed; exit 1 (brief reserves 2 for syntax/validation).
4. Absent nullable variable ⇒ argument omitted (GraphQL omission semantics), catalog
   defaults then apply — resolves the analysis open question; resolver-visible.
5. `init` also rejects unknown resolver keys (UNKNOWN_RESOLVER) — composition-time typo
   guard; `check` returns the full problem list; codes distinct from the 12 request codes.
6. New fixture `runtime-catalog.json` instead of mutating `gmail-catalog.json` — existing
   tests pin the current fixture's contents.
7. Enum-by-string accepted everywhere (variables and literals) alongside bare enum
   literals — consistent with the reused `GatewayVariableTypeCheck` wire rule.
8. Non-finite doubles rejected at coercion (arguments) and projection (results) so
   `jsonString` for `rawOutput` is total.
9. String/block-string decoding moves to internal `GraphQLStringDecoder` in the parser
   file; `SDLPrinterTests` uses it through `@testable` import. This preserves the SDL
   injection regressions without retaining any inliner API or adding public surface.
10. Nested selection arguments are rejected as `INVALID_SELECTION` before variable
    bookkeeping. The fixed root-resolver API receives neither nested arguments nor the
    selection tree, so rejection is the only fail-closed behavior without expanding the
    accepted public surface.
11. Coercion materializes singleton lists, Float values, input objects, and recursive
    defaults so every resolver-visible argument has its declared runtime shape.
12. `rawOutput` always includes `errors`, using `[]` on success, matching the accepted
    envelope contract exactly.
13. Non-`GatewayResolverError` failures expose only `RESOLVER_ERROR` and the stable
    message `"resolver failed"`; underlying descriptions are discarded to prevent
    provider, request, environment, or credential leakage.
14. Duplicate variable declarations and duplicate field arguments are positioned
    parser `.syntax` errors at the second name. The validator also rejects duplicate
    names in directly constructed ASTs with `DUPLICATE_VARIABLE` or
    `DUPLICATE_ARGUMENT`, so no first-wins document behavior reaches a resolver.
15. Fixed phase-0b resource limits are 262,144 UTF-8 bytes, 20,000 tokens, depth 32,
    1,000 selections, 64 root fields, 1,000 entries per list/object, 10,000 input or
    per-resolver-result nodes, and 8 concurrent query resolvers. These are internal
    safety policy for the new, unshipped runtime and require no operator decision or
    user-QA file; changing them later is an explicit compatibility review.
16. Text resource violations are positioned `SYNTAX`; direct-AST/input violations are
    `RESOURCE_LIMIT`; resolver-result violations are `RESOLVER_SHAPE`. Every input-side
    rejection is exit 2 with no path for global limits, an owning response-key path for
    local limits, and zero resolver calls. Resolver-result rejection is exit 1 after the
    bounded call and nulls only that root field.
