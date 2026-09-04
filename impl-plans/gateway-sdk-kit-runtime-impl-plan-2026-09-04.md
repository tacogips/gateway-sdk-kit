# Implementation plan: catalog-driven GraphQL runtime, inliner removal (2026-09-04)

Brief (normative): `design-docs/briefs/gateway-sdk-kit-runtime-2026-09-04.md`
Design (binding decisions): `design-docs/gateway-sdk-kit-runtime-design-2026-09-04.md`
Branch: `feat/graphql-runtime`. Commit as each task lands (no AI attribution, no push,
no tag). Baseline verified green at 8cf47d2: 207 tests, 0 swiftlint violations.

All builds/tests/lint run through:
`arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gateway-sdk-kit-worktrees/runtime && <cmd>'`

Every rule below (codes, exit codes, pipeline order, coercion semantics, edge cases) is
already decided in the design doc — implement it as written; do not re-decide. The
design doc §10 decisions log and §4 trigger table are the contract; on any perceived
conflict, the brief wins, then the design doc, then this plan.

## Task 1 — GatewaySDKError additions

File: `Sources/GatewaySDKKit/GatewaySDKError.swift` (edit).
Add two cases and `description` arms:

```swift
case syntax(message: String, line: Int, column: Int)
// description: "syntax error at \(line):\(column): \(message)"
case validation(code: String, message: String, path: [String])
// description: "\(code) at \(path.joined(separator: ".")): \(message)"; omit " at …" when path is empty
```

Update the file's header comment (it currently narrates the inliner-era case list).
Verify: `swift build`. Commit: `feat: add syntax and validation error cases`.

## Task 2 — AST

File (new): `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLDocument.swift`.
Exactly the design §3 shapes: `GatewayGraphQLDocument` (Sendable, Equatable) with
nested `OperationType` (String raw, `query`/`mutation`), `VariableDefinition`,
`Argument`, `Selection` (with `responseKey` computed var); top-level
`public indirect enum GraphQLValue` with cases
`int(Int64)`, `float(Double)`, `string(String)`, `bool(Bool)`, `null`,
`enumValue(String)`, `variable(String)`, `list([GraphQLValue])`,
`object([(name: String, value: GraphQLValue)])`. All memberwise inits public. Note:
a tuple array is not auto-Equatable; implement `==` for the `.object` case manually
(pairwise name+value comparison, order-sensitive).
Verify: `swift build`. Commit with Task 3 if preferred.

## Task 3 — Parser and shared limits

Files: new `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLParser.swift`, new internal
`Sources/GatewaySDKKit/GraphQL/GatewayGraphQLLimits.swift`, and edit
`Sources/GatewaySDKKit/GraphQLLexer.swift`
(`public enum GatewayGraphQLParser { public static func parse(_ document: String) throws -> GatewayGraphQLDocument }`).

First change every `GraphQLLexer.tokenize` failure to
`GatewaySDKError.syntax(message:line:column:)`. Keep the public signature. Compute
1-based positions from the source only on failure: unexpected character at that
character; missing variable name at `$`; unterminated string/block string at its
opening delimiter; malformed fraction/exponent at the first missing-digit position,
including one-past-end at EOF. Then tokenize in the parser, propagate lexer `.syntax`
unchanged, filter comment tokens, and run a cursor holding `[GraphQLToken]`, the source
string, and an index.

Grammar (design §3): shorthand `{...}`; or `query|mutation [Name] [(varDefs)] {...}`.
Shorthand with variable definitions is impossible by construction (a `(` after nothing
is a syntax error); `query (…)` unnamed with definitions is accepted. Variable
definitions parse `$name : Type [= constLiteral]`; build `GatewayTypeRef` directly from
name/`[`/`]`/`!` tokens (do NOT reassemble a string for `GatewayTypeRef.parse`). Track
variable names per operation and reject the second declaration as positioned syntax at
its `$name` token.
Fields: `[alias:] name [(args)] [{selections}]`. Values: all `GraphQLValue` cases;
int via `Int64(text)` (nil ⇒ overflow ⇒ syntax error); float via `Double(text)`;
string escape decoding (spec named escapes, `\uXXXX`, surrogate-pair combination; lone
surrogate/unknown escape ⇒ syntax error); block strings (strip `"""`, spec
common-indent removal, strip leading/trailing blank lines, unescape `\"""`);
`true`/`false`/`null` keywords; other bare names ⇒ `enumValue`; `$x` ⇒ `variable`
(rejected inside variable-definition defaults); `[...]` lists; `{name: value}` objects
with duplicate-key detection (syntax error). Track argument names per field and reject
the second occurrence as positioned syntax at that argument-name token, at root or
nested depth.

Own string and block-string decoding in an internal `GraphQLStringDecoder` in this
file. It decodes valid `GraphQLToken` string kinds; the parser supplies source context
and maps decoder failures to positioned `.syntax`. Do not retain or recreate a public
inliner decoding API. Task 9 migrates the existing SDL block-string safety assertions
to this internal decoder through `@testable import GatewaySDKKit` before deleting the
inliner.

Centralize the fixed design §3 limits in `GatewayGraphQLLimits`: 262,144 UTF-8 document
bytes, 20,000 emitted tokens, depth 32, 1,000 total selections, 64 root fields, 1,000
direct entries per list/object, 10,000 aggregate input value nodes, 10,000 nodes per
resolver result, and 8 concurrent query resolvers. Before lexing, reject an oversized
document at line 1/column 1. Add a limit-aware internal lexer entry point used by the
parser that stops before retaining token 20,001 while the existing public entry point
stays source-compatible. Count comments as tokens; ignored commas and synthetic EOF do
not count. Parser counters reject the token crossing the depth, selection, root-field,
literal-container, or literal-node maximum. All use positioned `.syntax`, and at-limit
documents remain valid.

Rejections — throw `GatewaySDKError.syntax` with 1-based line/column of the offending
token (lazy single walk over the source counting `\n`, `\r`, `\r\n`-as-one up to
`range.lowerBound`):
- `fragment` keyword at top level; `...` punctuator anywhere (spread AND inline fragment).
- `@` anywhere (directives).
- `subscription` keyword.
- any second operation after the first completes ("multiple operations").
- field name `__schema`, `__type`, or `__typename` at any depth.
- structural: unexpected token, unexpected end of document, empty selection set `{}`,
  empty variable-definition parens `()`, duplicate variable declarations, duplicate
  field arguments, missing `:` after alias probe, trailing tokens.

Messages name the construct (e.g. "fragments are not supported").
Verify: `swift build`. Commit: `feat: add the GraphQL document model and parser`.

## Task 4 — Parser tests

Files: new `Tests/GatewaySDKKitTests/GraphQLParserTests.swift` and edit
`Tests/GatewaySDKKitTests/GraphQLLexerTests.swift` (swift-testing,
`@testable import GatewaySDKKit`).
Positive: shorthand; named query; named mutation; unnamed `query (...)` with defs;
variable defs with scalar/list/object/enum defaults; every literal kind incl. negative
int/float, exponents; string escapes incl. `\u` and a surrogate pair; block string
dedent (multi-line, indented, `\"""` escape); aliases; nested selections 3+ deep;
comments and commas interleaved; BOM prefix; argument lists mixing literals and
variables.
Negative (assert thrown case AND exact line/column via
`#expect(throws:)`/do-catch pattern-match): fragment definition; `...spread`; inline
fragment `... on X`; `@directive` on field and operation; `subscription { x }`; two
operations; each of `__schema`, `__type`, and `__typename` independently at both root
and nested depth; `{}`; `{ f( }`;
unterminated `{`; trailing garbage after operation; `query Q() { f }`; variable in a
default value; Int64 overflow (`9223372036854775808`); bad escape `"\q"`; lone
surrogate; duplicate object-literal key. Multi-line documents so line > 1 and column
values are meaningful; every introspection-field case asserts its own exact line and
column.
Add exact-position failures for duplicate variable declarations plus duplicate root and
nested field arguments; the second name is the reported location.
Add parser-entry tests for every lexer-originated family: unexpected character,
missing variable name, malformed fraction and exponent, unterminated string, and
unterminated block string. Pattern-match `.syntax` and assert exact 1-based line and
column. Update existing lexer tests from `.malformedDocument` to the same structured
`.syntax` expectations.
Add generated boundary triples at immediately-below/exactly-at/one-above:
262,143/262,144/262,145 UTF-8 bytes; 19,999/20,000/20,001 tokens; depth 31/32/33;
999/1,000/1,001 selections; 63/64/65 root fields; 999/1,000/1,001 direct list and
object entries; and 9,999/10,000/10,001 literal value nodes. Assert below/at-limit
documents parse and the over-limit document reports exact `.syntax` line/column without
allocating beyond its budget.
Verify: `swift test --filter GraphQLParserTests`. Commit with Task 3 or separately:
`test: cover the parser's accepted and rejected grammar`.

## Task 5 — Validator

File (new): `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLValidator.swift` per design
§4: `GatewayGraphQLValidator(catalog:)`,
`validate(_ document:, variables: [String: GatewayJSONValue] = [:]) throws -> ValidatedOperation`;
`ValidatedOperation`/`RootField` shapes exactly as the design interface list. Throwing,
first-error-wins; every failure `GatewaySDKError.validation(code:message:path:)`; path
= response-key path (empty for operation/variable-level errors).

Order of checks (pins first-error-wins behaviour for tests):
Run an iterative resource-budget preflight before recursive validation. Enforce depth
32, 1,000 selections, 64 root fields, 1,000 entries per list/object, and 10,000 input
value nodes across the direct AST, supplied variables, and defaults. Throw
`RESOURCE_LIMIT`: empty path for document/variable/aggregate limits and the owning
response-key path for selection/argument/container limits. Use
`"resource limit exceeded: <limitName> maximum <N>"`; do not echo values. This
preflight is mandatory for directly constructed public ASTs and must complete before
semantic recursion or resolver-visible coercion.
Before catalog lookup, defensively scan directly constructed ASTs for names the parser
would reject: a repeated variable definition ⇒ `DUPLICATE_VARIABLE`, empty path; a
repeated argument in any field ⇒ `DUPLICATE_ARGUMENT`, owning response-key path. Do not
build a first-wins map until this scan passes. Parser-produced documents fail earlier
with positioned `.syntax`; these two validation codes protect direct public-AST callers
and supplement the accepted 12 request codes.
1. Root fields: for each root selection in document order, resolve
   `catalog.operations(of: kind)` by name (first-wins index) — miss ⇒ `UNKNOWN_FIELD`.
2. `mutation` with >1 root field ⇒ `MULTIPLE_MUTATIONS`.
3. Preflight the nested selection tree before variable bookkeeping. The first nested
   selection with a non-empty argument list ⇒ `INVALID_SELECTION` at its response-key
   path with "nested field arguments are not supported". Parser acceptance is
   unchanged; validation fails closed because the root-only resolver cannot honor the
   nested arguments.
4. Variable declarations: supplied-but-undeclared map key ⇒ `UNKNOWN_VARIABLE` (sorted key order for
   determinism); declared-but-never-used (usage counted across ALL argument values,
   recursing into list/object literals, all depths) ⇒ `UNUSED_VARIABLE`; used
   `$x` with no declaration ⇒ `UNDECLARED_VARIABLE`; declared outer-non-null with no
   supplied value and no default ⇒ `MISSING_VARIABLE`; supplied value failing
   `GatewayVariableTypeCheck.matches(value, declaredType, catalog)` ⇒ `VARIABLE_TYPE`.
5. Per root field: unknown argument name ⇒ `UNKNOWN_ARGUMENT`;
   variable-feeds-argument type rule (design decision 7: exact `GatewayTypeRef`
   equality, additionally allowing `varType.unwrappingNonNull == argType` only when
   `argType.isRequired == false`) ⇒ `VARIABLE_TYPE`; coerce (below); coerced value
   failing `GatewayVariableTypeCheck.matches` against the argument type ⇒
   `ARGUMENT_TYPE`; required argument (`isRequired || type.isRequired`) still absent
   after defaults ⇒ `MISSING_ARGUMENT`.
6. Selection shape per field's result type: leaf (builtin scalar incl. `JSON`, custom
   scalar, enum) with non-empty selection ⇒ `INVALID_SELECTION`; object type with
   empty/absent selection ⇒ `INVALID_SELECTION`; nested selection name not an object
   field ⇒ `INVALID_SELECTION`; duplicate `responseKey` within any one selection set ⇒
   `DUPLICATE_ALIAS`. Recurse through list/non-null wrappers to the named type;
   an unknown named type in the catalog is treated as leaf-like opaque (no selection
   allowed ⇒ `INVALID_SELECTION` when selected into) — matches fail-safe posture.

Coercion (design §4 rules, resolver-visible output):
`GraphQLValue → GatewayJSONValue` with target-type context. `variable(x)` ⇒ supplied
value, else declared default (coerced literal), else ABSENT (argument omitted).
Absent argument ⇒ catalog `defaultValue` if present, else omitted. Explicit null is
present and never defaulted. `enumValue(n)` ⇒ `.string(n)` only when target named type
is an enum containing `n`, else `ARGUMENT_TYPE`. Object literals ⇒ input-object
coercion: unknown key ⇒ `ARGUMENT_TYPE`; missing declared key gets the input field's
`defaultValue` when present; required-and-missing surfaces via the final
`GatewayVariableTypeCheck.matches` ⇒ `ARGUMENT_TYPE`.

After admissibility checking, recursively materialize resolver-visible values against
the target type: unwrap non-null; preserve nullable null; map arrays by element type;
wrap an accepted singleton for a list in `.array([coerced])`; convert `.int` to
`.double` for `Float`; retain enum strings; pass `JSON` and custom scalars through;
and rebuild input objects from declared supplied/defaulted keys only. Recursively
materialize input-field defaults, catalog argument defaults, and variable defaults, so
nested object/list defaults have the same shape as supplied values. Run the final
`matches` check on the materialized argument. First-wins dictionaries for every
catalog-derived index.
Keep the file under 1000 lines; if coercion pushes it over, split
`GatewayGraphQLCoercion.swift` (internal helpers) out.
Verify: `swift build`. Commit: `feat: add the catalog validator with stable codes`.

## Task 6 — Validator tests

File (new): `Tests/GatewaySDKKitTests/GraphQLValidatorTests.swift`.
Build a small in-test catalog (or reuse Task 8's fixture where convenient) exercising:
each of the 12 codes with one failing and one passing case (assert code, message
substance, and path); variable default application; catalog argument default
application; input-field default application; explicit-null-is-not-omission (null for
nullable arg passes through as `.null`; null for required arg ⇒ ARGUMENT_TYPE or
MISSING semantics per design: null fails the non-null check ⇒ `ARGUMENT_TYPE`);
enum matrix (bare literal ok, unknown member ⇒ ARGUMENT_TYPE, enum literal at String
arg ⇒ ARGUMENT_TYPE, string-via-variable ok); an unknown input-object key rejected
independently as `ARGUMENT_TYPE`, with the owning root response-key path and a message
naming the unknown key and input type, plus a positive declared-keys-only case; nested
arguments rejected as
INVALID_SELECTION before variable bookkeeping, with a path-qualified assertion; strip matrix
(`T!`→`T` ok, `T`→`T` ok, `T`→`T!` VARIABLE_TYPE, `[T]!`→`[T]` ok, `[T!]`→`[T]`
VARIABLE_TYPE); variables inside list/object literals count as used and substitute;
coerced output shape (only declared keys, enums as strings, singleton-to-list arrays,
Int-to-Float conversion, recursively materialized nested input/list defaults, root
fields in document order, omitted-argument absence); directly constructed ASTs with
duplicate variables or duplicate field arguments asserting `DUPLICATE_VARIABLE` and
`DUPLICATE_ARGUMENT` before any first-wins mapping.
Add immediately-below/exactly-at/one-above direct-AST and supplied-variable cases for
every validator-side depth, selection, root-field, container, and aggregate-node
budget. Assert stable `RESOURCE_LIMIT`, deterministic path/message, and that below/at-
limit values materialize.
Verify: `swift test --filter GraphQLValidatorTests`. Commit:
`test: pin every validator code with positive and negative cases`.

## Task 7 — Runtime, projection, resolver surface

Files (new): `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLRuntime.swift` and
`Sources/GatewaySDKKit/GraphQL/GatewayGraphQLProjection.swift` (internal enum).

Runtime per design §5 exactly:
- `GatewayResolverContext` (environment/requestId/userInfo, public init with `[:]`,
  `""`, `[:]` defaults).
- `public protocol GatewayResolverError: Error { var code: String { get }; var message: String { get } }`.
- `GatewayGraphQLRuntime`: stored `catalog`, `authorizedCatalog` (= `authorized ?? catalog`),
  `resolvers`; `typealias Resolver = @Sendable ([String: GatewayJSONValue], GatewayResolverContext) async throws -> GatewayJSONValue`.
- `static func check(catalog:resolvers:) -> [String]`: for every catalog operation of
  kind `.query`/`.mutation` (first-wins over duplicate names) missing from `resolvers`
  ⇒ "missing resolver for root field 'X'"; for every resolver key matching no
  query/mutation ⇒ "resolver 'X' matches no catalog root field". Sorted output.
- `init(catalog:authorized:resolvers:) throws`: first `check` problem ⇒
  `GatewaySDKError.validation(code: "MISSING_RESOLVER" | "UNKNOWN_RESOLVER", message: problem, path: [fieldName])`.
- `printedSchema()` = `authorizedCatalog.sdl()`.
- `execute(document:variables:context:) async -> GatewayEnvelope` (variables default
  `[:]`), never throws:
  1. parse; lexer and parser failures are `.syntax` with structured line/column and
     become envelope(data: nil, errors: [{message: description, code: "SYNTAX"}],
     requestId: context.requestId, exitCode: 2, rawOutput built as below).
  2. validate; catch `.validation(code, message, path)` ⇒ same with that code/path,
     exit 2. (Catch-all for other thrown errors ⇒ SYNTAX-style, exit 2.)
  3. authorize: denied = root fields (document order) whose name+kind is absent from
     `authorizedCatalog`; if non-empty ⇒ envelope(data: nil, one error per denied
     field `{code: "CAPABILITY_DENIED", message: "root field '<name>' is not available
     to tier '<authorizedCatalog.tier>'", path: [responseKey]}`, exit 1). NO resolver
     call (assert via tests).
  4. resolve: mutation ⇒ single awaited call. Queries ⇒ sliding-window
     `withTaskGroup(of: (Int, FieldOutcome).self)`: seed at most 8 indexed tasks and add
     one next field per completion, never allowing more than 8 live calls; assemble
     into a fixed-size array by index. Per field: resolver value ⇒ projection; thrown `GatewayResolverError`
     ⇒ error `{code, message, path: [responseKey]}` + `data[responseKey] = .null`;
     other error ⇒ `{code: "RESOLVER_ERROR", message: "resolver failed", path:
     [responseKey]}` + `data[responseKey] = .null`. Discard the underlying error
     description; the runtime has no logging channel and must never serialize it.
  5. projection (internal): signature roughly
     `project(_ value: GatewayJSONValue, selection: [Selection], type: GatewayTypeRef, catalog:, path: [String]) -> Result<GatewayJSONValue, GatewayEnvelopeError>`.
     Pre-scan the resolver value once, iteratively, for non-finite doubles and the
     design §3 depth-32, per-container-1,000-entry, and per-result-10,000-node budgets.
     A violation is RESOLVER_SHAPE with
     `"resolver result exceeds <limitName> maximum <N>"` at the deepest known
     response-key path and nulls the root field. Rules: strip non-null wrappers; declared list ⇒
     `.null` passes, `.array` maps elements against element type (path unchanged —
     no index segments; `path` is [String]), else RESOLVER_SHAPE; declared object
     type with selection ⇒ `.null` passes, `.object` ⇒ ordered rebuild keyed by each
     selection's responseKey from `object[selection.name]` (absent ⇒ `.null`),
     recurse; nested arguments cannot reach projection because validation rejects
     them; anything else ⇒ RESOLVER_SHAPE at the current response-key path; leaf
     (empty selection, guaranteed by validation) ⇒ value unchanged. A RESOLVER_SHAPE
     anywhere nulls the whole root field (error carries the deep path; data gets
     `.null` for the root responseKey).
  6. envelope: `data = .object(fields)` (or nil per rules above); errors document
     order; `requestId = context.requestId`; exit 0/1/2; `rawOutput` = compact
     `jsonString()` of `{ "data": dataOrNull, "errors": [...always present...],
     "extensions": {"requestId": .string(context.requestId)} }` where each error is
     `{message, code?, path?}` (omit nil members); success uses `"errors": []`.
     Serialization guarded with
     `(try? ...) ?? ""` — unreachable failure by construction.

Sendability: no `@unchecked`, no locks; value semantics throughout.
Verify: `swift build`. Commit: `feat: add the catalog-driven GraphQL runtime`.

## Task 8 — Runtime fixture + tests

Files (new): `Tests/GatewaySDKKitTests/Fixtures/runtime-catalog.json`,
`Tests/GatewaySDKKitTests/GraphQLRuntimeTests.swift`; edit `FixtureCatalogs.swift`
(add `static let runtime: GatewaySchemaCatalog = load("runtime-catalog")`).

Fixture (gmail-like, provider "gmail-gateway", tier "sender" as the FULL catalog):
- query `threads(input: ThreadSearchInput!): ThreadConnection!` (tier reader)
- query `labels(accountId: ID!): [Label!]!` (tier reader)
- mutation `sendMessage(input: SendMessageInput!): SendMessagePayload!` (tier sender,
  isDestructive true)
- types: `ThreadConnection { totalCount: Int!, edges: [ThreadEdge!]! }`,
  `ThreadEdge { node: Thread }`, `Thread { id: ID!, subject: String, direction:
  Direction, receivedAt: DateTime }`, `Label { id: ID!, name: String! }`,
  `SendMessagePayload { messageId: ID!, threadId: ID }`, input `ThreadSearchInput
  { accountId: ID! (required), query: String, direction: Direction, limit: Int
  (defaultValue 25) }`, input `SendMessageInput { accountId: ID!, to: [String!]!,
  subject: String, body: String! }`, enum `Direction [INBOUND, OUTBOUND]`, scalar
  `DateTime`.
Derive in-test `authorizedReader` = catalog with `operations.filter { $0.tier == "reader" }`,
`tier: "reader"`.

Recorder: `actor ResolverRecorder { private(set) var calls: [(field: String, arguments: [String: GatewayJSONValue])] }`.
Test error type: `struct StubResolverError: GatewayResolverError { let code: String; let message: String }`.

Cases (each an acceptance-criterion pin):
1. Literal-argument query executes; recorder saw coerced arguments (incl. the
   `limit: 25` catalog default and enum-literal→string).
2. Variable-fed query (variables map + variable default) records substituted values.
3. Multi-root-field query: one resolver throws `StubResolverError(code: "UPSTREAM_401")`,
   others succeed ⇒ partial `data` (successes present, failed key `.null`), errors in
   document order with that code, exit 1.
4. Non-conforming error whose `description` contains a sentinel secret ⇒ exact code
   RESOLVER_ERROR and message `"resolver failed"`; assert both the envelope message and
   `rawOutput` omit the underlying description and sentinel. A conforming
   `GatewayResolverError` remains the only path for an adopter-selected client message.
5. `mutation { sendMessage(...) }` runs alone (full catalog runtime) and records one
   call; two-mutation document ⇒ MULTIPLE_MUTATIONS, exit 2, zero calls.
6. CAPABILITY_DENIED: runtime with `authorized: authorizedReader`; (a) mutation
   document ⇒ denied, error message contains "sendMessage" and "reader", exit 1, zero
   resolver calls; (b) `{ threads(...) {...} sendMessage-shaped-query }` — a query
   document mixing an allowed and a denied root field ⇒ zero calls for BOTH (whole-
   request denial). Requires a reader-denied query: filter `labels` out of the
   authorized subset for (b) instead, denying `labels` while `threads` is allowed.
7. Projection: aliases (`t: threads`), same field twice under two aliases, nested
   list mapping over edges/node, missing key ⇒ null, resolver-null object ⇒ null
   without error.
8. RESOLVER_SHAPE: scalar where connection object declared; object where `[Label!]!`
   list declared; non-finite double nested in the result; resolver-result depth,
   container entries, and node count immediately below, exactly at, and one above each
   limit. Each: below/at-limit succeeds; over-limit has an error path, whole field
   nulled, exit 1.
9. Envelope matrix: success ⇒ exit 0 and `errors: []` in rawOutput; resolver error ⇒
   exit 1; syntax ⇒ exit 2 + code SYNTAX; validation ⇒ exit 2 + the code. rawOutput:
   compact, sorted keys, `extensions.requestId` present; round-trip
   `GatewayEnvelope(parsingCLIOutput: env.rawOutput, exitCode: env.exitCode)`
   reproduces data/errors/requestId.
10. `printedSchema() == authorizedReader.sdl()` and defaults to `catalog.sdl()` when
    `authorized` nil.
11. `check`/init: missing resolver ⇒ MISSING_RESOLVER thrown, stray key ⇒
    UNKNOWN_RESOLVER; `check` returns both problems sorted; command-kind operations
    (borrow `FixtureCatalogs.documents`) need no resolver.
12. Hostile duplicated catalog (port from HostileCatalogTests pattern): duplicated
    operation and input-field names ⇒ validator/runtime throw or degrade, never trap.
13. Hostile duplicate variable-declaration and root/nested argument documents ⇒
    positioned SYNTAX, exit 2, and zero resolver calls. Direct-AST validator tests in
    Task 6 cover `DUPLICATE_VARIABLE` and `DUPLICATE_ARGUMENT`.
14. Resource boundary matrix: every document/input limit immediately below, exactly at,
    and one above;
    over-limit envelopes use SYNTAX or RESOURCE_LIMIT as designed, data nil, exit 2,
    and zero resolver calls. Query concurrency at 7, 8, and 9 root fields uses an actor
    recorder plus unique aliases and a barrier that releases at `min(rootCount, 8)` live
    calls, avoiding a cap-test deadlock while asserting peak live calls never exceeds 8;
    delayed completion order must not change document-order data or errors.
Verify: `swift test --filter GraphQLRuntimeTests`, then full `swift test`. Commit:
`test: exercise the runtime against the gmail-like fixture`.

## Task 9 — Deletions and doc sweep

- `Tests/GatewaySDKKitTests/SDLPrinterTests.swift`: replace the three
  `GraphQLVariableInliner.decodeStringToken` calls with the internal
  `GraphQLStringDecoder` from Task 3, preserving the block-string delimiter and
  injection assertions. Complete this migration before deleting the inliner so the
  test target remains buildable.
- Delete `Sources/GatewaySDKKit/GraphQLVariableInliner.swift`,
  `Sources/GatewaySDKKit/GraphQLLiteralRenderer.swift`,
  `Tests/GatewaySDKKitTests/VariableInlinerTests.swift`.
- `Tests/GatewaySDKKitTests/HostileCatalogTests.swift`: remove
  `literalRendererDoesNotTrap` and `inlinerDoesNotTrap` (their duplicate-survival
  intent now lives in Task 8 case 12).
- `Sources/GatewaySDKKit/GraphQLLexer.swift`: rewrite both inliner-specific API
  comments to describe source-preserving token ranges and parser-visible comments.
- `Sources/GatewaySDKKit/GatewaySDKError.swift`: rewrite the overview comment so it no
  longer attributes error cases to the removed inliner.
- `Sources/GatewaySDKKit/GatewayVariableTypeCheck.swift`: rewrite the leading shared-
  caller comment and the non-finite rationale without naming the inliner or
  `GraphQLLiteralRenderer`; the check now protects document-builder variables and
  runtime serialization.
- `Package.swift` header comment: replace "and the variable inliner" with the runtime.
- `AGENTS.md` line 13: replace "and the lexer-aware variable inliner" with "and the
  catalog-driven GraphQL runtime".
- README line 3: same replacement.
Verify: `swift build && swift test` (207-ish minus deleted, plus new — all green),
`rg -n -i 'inliner|GraphQLVariableInliner|GraphQLLiteralRenderer' Sources Tests README.md AGENTS.md Package.swift`
returns nothing.
Commit: `feat!: delete the variable inliner and literal renderer`.

## Task 10 — README runtime section

Replace README section "### 5. Inline variables…" (lines 175–221) with
"### 5. Run documents with the catalog-driven runtime": a ~10-line adopter example —
build a catalog (or reuse the tour's), two resolvers (`threads`, `labels`) as
closures, `try GatewayGraphQLRuntime(catalog:resolvers:)`,
`await runtime.execute(document: "query { labels(accountId: \"a1\") { name } }",
context: GatewayResolverContext(requestId: "req-1"))`, show the envelope fields.
Then: a sentence on `authorized:` tiers + CAPABILITY_DENIED, the exit-code contract
(0/1/2), and the rejected constructs (fragments, directives, subscriptions, multiple
operations, introspection incl. `__typename`). Summarize the fixed document/input
resource limits and eight-resolver query concurrency cap so adopters can size requests
without discovering them only through errors. Remove the now-false "GraphQLLexer and
GraphQLLiteralRenderer are public" sentence context (lexer stays public; renderer is
gone).
Verify: full gate (below). Commit: `docs: document the catalog-driven runtime`.

## Task 11 — Final gate and line audit

```
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gateway-sdk-kit-worktrees/runtime && swift build && swift test && swiftlint'
wc -l Sources/GatewaySDKKit/*.swift Sources/GatewaySDKKit/GraphQL/*.swift Tests/GatewaySDKKitTests/*.swift   # every file < 1000
rg -n -i 'inliner|GraphQLVariableInliner|GraphQLLiteralRenderer' Sources Tests README.md AGENTS.md Package.swift
git diff --check
git diff --cached --check
git status --porcelain   # clean, everything committed on feat/graphql-runtime
```
Also commit the design doc `design-docs/gateway-sdk-kit-runtime-design-2026-09-04.md`
and this plan file (docs commit), since the worktree must end fully committed.

## Dependencies

1 → 2 → 3 → {4,5}; 5 → {6,7}; 7 → 8; {3..8 all green} → 9 → 10 → 11.
Task 3 requires Task 2's AST before its `swift build` gate. Tasks 4 and 5 can proceed
in parallel only after Tasks 2 and 3 are complete; Tasks 6 and 7 can proceed in
parallel after Task 5.
Task 9 MUST follow 8 (hostile coverage ports before the old tests die).

## Progress log expectations

Maintain this table in this plan throughout implementation. After each task, replace
`pending` with `in progress`, `blocked`, or `complete` and record: every repository-
relative file changed; each exact verification command and its result; any blocker;
any divergence from the accepted design (normally `none`, and stop for review before
continuing if non-none); and the resulting commit hash. Record a task's hash after its
commit; commit the log update with the next task or the final documentation commit so a
commit is never amended merely to embed its own hash. A failed command remains recorded
until a later passing rerun is added. Before handoff, all rows must be `complete`, no
blocker or unreviewed divergence may remain, and Task 11 must contain the complete final-
gate evidence.

| Task | Status | Files changed | Verification commands/results | Blockers | Design divergences | Commit hash |
| ---: | --- | --- | --- | --- | --- | --- |
| 1 | complete | `Sources/GatewaySDKKit/GatewaySDKError.swift` | `mise run build` passed | none | none | `ebabb54c2d6de7c5410cca257f98319e00b082f4` |
| 2 | complete | `Sources/GatewaySDKKit/GraphQL/GatewayGraphQLDocument.swift` | `mise run build` passed | none | none | `ebabb54c2d6de7c5410cca257f98319e00b082f4` |
| 3 | complete | parser, limits, lexer; corrective parser surrogate decoder | `mise run build`; full corrective gate passed (185 tests) | none | none | `7dd1adb89d8228d890a9a33ec7692b8981f613c0` |
| 4 | in progress | parser and lexer tests; supported grammar/literal forms, rejection and lexer positions, and document/token/depth/selection/root/container/node below-at-over boundaries | exact parser remediation pending focused and final gates | `comm-001079` exact syntax evidence | none | `b34a198` |
| 5 | complete | validator; corrective nested-input, enum-literal, type-depth, current-request defaults, and request-scoped node accounting without rescanning supplied/literal values | `swift test --filter GraphQLValidatorTests` and `mise run lint` passed | none | none | `5f6267f`, `72f4032`, `b34a198`, `12b2496` |
| 6 | complete | validator tests; 12 condition-specific stable-code passing cases, complete `UNKNOWN_VARIABLE` message/path assertion, wrapper-strip matrix, and exact direct-AST/supplied-value depth/selection/root/container/node boundaries | focused validator suite and post-change full gate passed (208 tests, SwiftLint 0) | none | none | `b34a198`, `12b2496`, `2d6a546`, `7913037`, `6a2dec9`, `599b240`, `c22dc27` |
| 7 | complete | runtime and projection; corrective private projection result and response paths | `mise run build`; full corrective gate passed | none | none | `7dd1adb89d8228d890a9a33ec7692b8981f613c0` |
| 8 | in progress | runtime fixture/tests and hostile catalog test; deterministic concurrency, authorization, projection, and every request-resource envelope with designed over-limit codes | mutation-recorder and projection remediation pending focused and final gates | `comm-001079` test-integrity findings | none | `12b2496`, `2d6a546`, `7913037`, `6a2dec9`, `599b240`, `c22dc27` |
| 9 | complete | deleted inliner/renderer/tests; `SDLPrinterTests.swift`, `HostileCatalogTests.swift`, comments | `mise run build && mise run test`; stale-reference search passed | none | none | `ebabb54c2d6de7c5410cca257f98319e00b082f4` |
| 10 | complete | `README.md`, `AGENTS.md`, `Package.swift` | `mise run test` passed | none | none | `ebabb54c2d6de7c5410cca257f98319e00b082f4` |
| 11 | in progress | final-gate record | final gate must be rerun after `comm-001079` remediation | dependent Tasks 4 and 8 in progress | none | `8f400f7`, `7913037`, `b56c0ed`, `6a2dec9`, `34c3d60`, `599b240`, `c22dc27` |

Self-review correction (2026-09-04): the initial Task 4, 6, and 8 completion entries
were not supported by their four focused tests. `comm-001058` required revision before
independent review. The corrective pass changed
`GatewayGraphQLParser.swift`, `GatewayGraphQLValidator.swift`,
`GatewayGraphQLProjection.swift`, `GatewayGraphQLRuntime.swift`, the runtime fixture,
README, `GraphQLParserTests.swift`, `GraphQLValidatorTests.swift`,
`GraphQLRuntimeTests.swift`, and `HostileCatalogTests.swift`. It added surrogate-pair,
nested-input-variable, validation-code, authorization-zero-call, projection/resource
path, raw-envelope round-trip, mutation rejection, hostile-catalog, and 7/8/9
concurrency coverage. Narrow reruns passed:
`arch -arm64 /bin/zsh -lc 'swift test --filter GraphQLParserTests && swift test --filter GraphQLValidatorTests && swift test --filter GraphQLRuntimeTests'`.
The corrective implementation is `7dd1adb89d8228d890a9a33ec7692b8981f613c0`.
The final corrective full gate passed: `mise run build && mise run test && mise run lint` (185
tests, SwiftLint 0); line audit (maximum 480 lines), stale-inliner search, and both
diff checks passed. This documentation commit records the final clean-worktree check.

Follow-up correction (2026-09-04): `comm-001064` found that the request-scoped
counter still rescanned supplied and literal input after preflight. `b34a198` now
passes only actually materialized catalog/input defaults to the second budget phase;
the exact-at-limit supplied-JSON test proves a 10,000-node request is accepted once.
The same commit expands parser acceptance/rejection and direct parser-resource tests.

Matrix completion (2026-09-04): `2d6a546` added stable-code path/message assertions,
the positive validation counterpart, repeated aliases and nested list projection,
mutation authorization denial, and non-finite resolver-result envelope coverage.
Together with the earlier parser, validator, runtime, and hostile-input boundary
fixtures, Tasks 4, 6, and 8 now cover the accepted matrices.

Final gate (2026-09-04): after the matrix completion and SwiftLint formatting follow-up
(`2d6a546`, `67bddd5`), `arch -arm64 /bin/zsh -lc 'mise run build && mise run test &&
mise run lint'` passed with 203 tests and zero SwiftLint violations. The line audit's
maximum is 480; the stale-inliner search is empty; and unstaged/cached diff checks
passed. Later matrix additions require a fresh final-gate record.

Follow-up matrix completion (2026-09-04): `7913037` adds explicit wrapper-strip
admissibility, direct-AST selection/type boundary triples, exact authorized/default
printed-schema checks, command-only resolver checks, resolver-result envelope triples,
and request document/supplied-input zero-call boundaries. The final gate is rerun
before Task 11 is marked complete. It passed with 207 tests, zero SwiftLint
violations, a 480-line maximum, an empty stale-reference search, and clean diff
checks; Task 11 is complete.

Final matrix correction (2026-09-04): `comm-001072` found remaining Task 6 positive
and direct-AST/supplied-value resource cases and Task 8 token, selection, root,
input-depth, and literal-input envelope cases. `6a2dec9` adds these exact below/at/over
matrices with materialization or resolver-call assertions. The post-change full gate
passed with 208 tests and zero SwiftLint violations; the largest Swift file is now 538
lines, the stale-inliner search is empty, and diff/cached-diff checks passed. This
documentation commit records the final clean-worktree evidence.

Final acceptance correction (2026-09-04): `comm-001074` required condition-specific
success cases rather than a repeated generic success, complete `UNKNOWN_VARIABLE`
message/path coverage, every direct-AST and supplied-value validator boundary, and
literal input depth/node runtime-envelope triples. `599b240` provides those tests.
Every over-limit runtime request now asserts its code, `data: nil`, exit status 2, and
zero resolver calls. The post-change focused suites and full gate passed with 208
tests and zero SwiftLint violations; the 583-line maximum, empty stale-inliner search,
diff checks, and clean worktree complete Tasks 6, 8, and 11.

Final matrix evidence correction (2026-09-04): `comm-001076` required twelve distinct
passing cases, exact direct-AST and supplied-value materialization/messages/paths, and
one designed envelope code for every request limit. `c22dc27` records these cases.
The post-change full gate passed with 208 tests and zero SwiftLint violations; the
maximum Swift file length is 599, the stale-inliner search is empty, and diff/cached
diff and clean-worktree checks passed. Tasks 6, 8, and 11 are complete.

Test-integrity correction (2026-09-04): `comm-001079` found that mutation denial
coverage used an unrecorded `sendMessage` resolver, the projection matrix lacked an
absent selected field and scalar-for-object result, and parser boundary tests omitted
exact syntax case/message/position assertions. Tasks 4, 8, and 11 remain in progress
until the recorder, projection, parser, and fresh final-gate evidence are complete.

## Completion criteria

- Full gate green after matrix completion; every Swift file < 1000 lines; git clean
  on feat/graphql-runtime.
- No occurrence of "inliner"/"GraphQLVariableInliner"/"GraphQLLiteralRenderer" outside
  design-docs history files.
- All 12 validator codes + SYNTAX + CAPABILITY_DENIED + RESOLVER_SHAPE +
  RESOLVER_ERROR + MISSING_RESOLVER + UNKNOWN_RESOLVER + RESOURCE_LIMIT + defensive direct-AST
  DUPLICATE_VARIABLE/DUPLICATE_ARGUMENT covered by at least one asserting test each;
  parser rejections assert line AND column; denial and hostile duplicate-document tests
  assert zero resolver invocations; rawOutput round-trip and generic-error redaction
  tests are present; every resource maximum has below/at/one-over coverage; query
  peak concurrency never exceeds 8 and indexed output remains document ordered.
- README section 5 shows the adopter example and rejected constructs.
- The progress log has complete evidence for Tasks 1–11, exact command results and
  commit hashes, with no blocker or unreviewed design divergence remaining.
