# Brief: add the catalog-driven GraphQL runtime to `GatewaySDKKit`, remove the inliner (2026-09-04)

Master design: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`
(section 2.6 is normative for this brief; section 3.4 explains the first adopter,
gmail-gateway). The package already implements the catalog model, SDL printer, search,
builders, `GatewaySDK` and `GatewayEnvelope` (see `README.md` and
`design-docs/briefs/gateway-sdk-kit-2026-09-04.md`). Treat this whole brief as exactly
ONE feature.

## Operator decision

`GraphQLVariableInliner` was a stop-gap to give gmail-gateway variables without a parser.
The operator rejected that approach: gmail-gateway will replace its substring scanner
with a proper runtime, and no backward compatibility is required. So:

1. **Delete** `GraphQLVariableInliner` and everything only it used (keep the lexer and
   `GraphQLLiteralRenderer` only if the runtime below reuses them; otherwise delete).
   Remove them from README and tests.
2. **Add** `GatewayGraphQLRuntime`, a credential-free, transport-free GraphQL executor
   driven by a `GatewaySchemaCatalog` and a resolver table, so a gateway without its own
   runtime can adopt it wholesale.

## Deliverables

### 1. Document model and parser (`Sources/GatewaySDKKit/GraphQL/`)

- `GraphQLLexer` (reuse the existing one; tokens with source positions for error
  messages: line/column).
- `GatewayGraphQLDocument` AST: `operationType` (query | mutation), optional `name`,
  `variableDefinitions: [VariableDefinition { name, type: GatewayTypeRef, defaultValue:
  GraphQLValue? }]`, `selectionSet: [Selection]`; `Selection { alias: String?, name,
  arguments: [Argument { name, value: GraphQLValue }], selectionSet: [Selection] }`;
  `GraphQLValue` = int, float, string, bool, null, enum(name), variable(name), list,
  object.
- `GatewayGraphQLParser.parse(_ document: String) throws -> GatewayGraphQLDocument`.
  Supported: one operation per document (anonymous `{ ... }` or `query|mutation Name(...)
  { ... }`), variable definitions with defaults, arguments as literals or variables,
  nested selection sets, aliases, comments, block strings. Rejected with a clear
  `GatewaySDKError.syntax(message, line, column)`: fragments and spreads, directives,
  subscriptions, multiple operations, introspection fields (`__schema`, `__type`;
  `__typename` is also rejected).

### 2. Validator

`GatewayGraphQLValidator(catalog:)` with `validate(_ document:, variables: [String:
GatewayJSONValue]) throws -> ValidatedOperation`:
- every root field exists in the catalog with the operation's kind (query field under
  `query`, mutation field under `mutation`); mutations have exactly one root field;
- arguments: unknown → error; required missing → error; values type-checked against the
  argument type (reuse the builder's type check; enums by value; input objects by
  declared fields, required fields, unknown keys);
- variables: declared-but-unused, used-but-undeclared, unknown supplied, required (`!`)
  without value and without default, type mismatch between a variable's declared type and
  the argument it feeds (exact match of `GatewayTypeRef` after stripping an outer
  non-null when the argument is optional), and value type check of supplied values;
- selection sets: a field selected on an object type must exist on that type; leaf fields
  (scalars, enums, `JSON`) must not have a selection set; object-typed fields must have a
  non-empty selection set; aliases must be unique per selection set;
- output: the validated tree with variables substituted and arguments coerced to
  `[String: GatewayJSONValue]` per root field (defaults applied, enums as strings, input
  objects as objects with only declared keys).
- Every validation error is `GatewaySDKError.validation(code: String, message: String,
  path: [String])` with stable codes: `UNKNOWN_FIELD`, `UNKNOWN_ARGUMENT`,
  `MISSING_ARGUMENT`, `ARGUMENT_TYPE`, `UNKNOWN_VARIABLE`, `UNUSED_VARIABLE`,
  `UNDECLARED_VARIABLE`, `MISSING_VARIABLE`, `VARIABLE_TYPE`, `INVALID_SELECTION`,
  `MULTIPLE_MUTATIONS`, `DUPLICATE_ALIAS`.

### 3. Runtime

```swift
public struct GatewayResolverContext: Sendable {
  public var environment: [String: String]
  public var requestId: String
  public var userInfo: [String: GatewayJSONValue]     // free-form, for the adopter
}
public struct GatewayGraphQLRuntime: Sendable {
  public typealias Resolver = @Sendable (_ arguments: [String: GatewayJSONValue], _ context: GatewayResolverContext) async throws -> GatewayJSONValue
  public init(catalog: GatewaySchemaCatalog, authorized: GatewaySchemaCatalog? = nil, resolvers: [String: Resolver])
  public func execute(document: String, variables: [String: GatewayJSONValue] = [:], context: GatewayResolverContext) async -> GatewayEnvelope
  public func printedSchema() -> String              // authorized catalog SDL
}
```
- `init` validates that every root field of `catalog` has a resolver (`precondition`-free:
  throw or return a problem list via a static `check` helper; choose `init(...) throws`).
- Pipeline: parse → validate against `catalog` → **authorize** against `authorized`: a
  root field present in `catalog` but absent from `authorized` yields an envelope error
  `code: "CAPABILITY_DENIED"`, message naming the field and `authorized.tier`, without
  calling any resolver → call resolvers for root fields in document order (queries may
  run concurrently; the mutation runs alone) → project each resolver result onto the
  requested selection set → envelope.
- Projection: object selection copies only requested fields, honouring aliases, recursing
  into nested objects and mapping over lists; a key absent from the resolver result
  becomes `null`; a resolver result that is not an object (or list of objects) for an
  object-typed field is an error `RESOLVER_SHAPE`.
- Resolver errors: if the thrown error conforms to a new `GatewayResolverError` protocol
  (`code: String`, `message: String`), the envelope error carries that code and the
  field's path and `data[field]` is `null`; other errors become `code: "RESOLVER_ERROR"`.
  A query with several root fields returns partial data plus errors.
- Envelope: `data` object keyed by alias or field name, `errors`, `requestId` from the
  context, `exitCode` 0 on success, 1 when any error, 2 on syntax / validation errors;
  `rawOutput` = the compact JSON `{data, errors, extensions: {requestId}}` string.

### 4. Tests (swift-testing)

- Parser: every supported construct, every rejected construct with line/column.
- Validator: each error code with a positive and a negative case, variable default
  application, input-object coercion, enum validation, nested selection validation,
  aliases.
- Runtime: fixture catalog (gmail-like: `threads(input: ThreadSearchInput!)` connection,
  `sendMessage(input:)`, `labels(accountId:)`) with fake resolvers recording arguments;
  concurrent queries with partial errors; mutation single-field rule; authorization
  denial without resolver call; projection with aliases, lists, missing keys, wrong shape;
  envelope exit codes and rawOutput shape; `printedSchema()`.
- Remove inliner tests; keep lexer tests.

### 5. Docs

README: replace the inliner section with a "Catalog-driven runtime" section showing a
10-line adopter example (catalog + two resolvers + execute). Note the rejected constructs.

## Verification

`arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gateway-sdk-kit-worktrees/runtime && swift build && swift test && swiftlint'`
green; no file over 1000 lines; commit on `main`; do not push.

## Non-goals

No networking, no credentials, no gateway-specific code, no dependencies, no CLI target,
no fragments/directives/introspection support.
