# Brief: implement `GatewaySDKKit` (2026-09-04)

Master design: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`
(section 2 is normative for this package; read it first). This brief is the
package-local contract. Treat the whole brief as exactly ONE feature.

## Goal

Implement the dependency-free library `GatewaySDKKit` in this package so that five
sibling gateway packages (wrike-gateway, google-analytics-gateway, apple-gateway,
gmail-gateway, google-documents-gateway) can each ship a thin `<Name>GatewaySDK` facade
on top of it, and riela can wrap those facades with one generic add-on engine.

The package already builds (placeholder `GatewaySDKKitVersion`). Keep that type.

## Deliverables (public API)

All types `Sendable`; model types also `Codable` and `Equatable`. Foundation only.
Swift 6 language mode. No dependencies. Must compile on Linux (no Darwin-only APIs;
`Regex` from the Swift standard library is fine).

### 1. JSON value

```swift
public enum GatewayJSONValue: Codable, Sendable, Equatable, Hashable {
  case null, bool(Bool), int(Int), double(Double), string(String)
  case array([GatewayJSONValue]), object([String: GatewayJSONValue])
}
```
- `init(any: Any) throws` (from `JSONSerialization` output: NSNull, NSNumber (bool vs
  int vs double distinguished), String, [Any], [String: Any]).
- `var anyValue: Any` (inverse), `func jsonString(pretty: Bool = false) throws -> String`,
  `static func parse(_ json: String) throws -> GatewayJSONValue`.
- Object encoding must be key-sorted so output is stable.

### 2. Catalog model

Exactly the types in master design §2.2: `GatewaySchemaCatalog`, `GatewayOperation`
(+ `Kind`), `GatewayArgument`, `GatewayTypeRef`, `GatewayNamedType` (+ `Kind`),
`GatewayField`. Plus:

- `GatewayDefinitionKind: String, Codable, CaseIterable` = `query, mutation, command,
  object, inputObject, enumeration, scalar`.
- `GatewaySchemaCatalog.builtinScalars: Set<String>` = `ID String Int Float Boolean JSON`.
- `func namedType(_ name: String) -> GatewayNamedType?`, `func operation(named:) ->
  GatewayOperation?`, `func operations(of kind:)`.
- `func validate() -> [GatewaySchemaProblem]` (`struct GatewaySchemaProblem { path,
  message }`): unknown type references (arguments, fields, results, input fields),
  duplicate operation names, duplicate type names, required argument with a default
  value, operation `kind == .command` with a non-nil `result` is allowed (opaque JSON)
  but `.query`/`.mutation` with nil result is a problem, enum with no values,
  object with no fields.
- `GatewayTypeRef` helpers: `namedTypeName`, `isRequired` (outer nonNull), `isList`,
  `graphQLString` (`[Foo!]!`), `static func parse(_ graphQL: String) throws`.

### 3. SDL printer

`extension GatewaySchemaCatalog { public func sdl() -> String }` printing in this stable
order: custom scalars (`scalar X`), enums, input objects, objects, then `type Query`,
`type Mutation` (omitted when empty), and for command catalogs `type Command` with one
field per command whose arguments are the flags. Field arguments print inline
`field(arg: Type!, other: [Int])`. Descriptions print as `"""..."""` block strings
above the definition when present. Also
`public func sdlFragment(for kind: GatewayDefinitionKind, name: String) -> String?` that
prints exactly one definition (used by search matches).

### 4. Schema search

`GatewaySchemaSearch` exactly as in master §2.4. Pattern compiled with `try Regex(pattern)`
(throw `GatewaySDKError.invalidPattern` on failure). Matched fields: definition name,
argument names, object field names, input field names, enum values, summary /
description. `matchedOn` lists what matched (`"name"`, `"argument:accountId"`,
`"field:subject"`, `"value:ROWS"`, `"summary"`). Ordering: exact whole-name matches
first, then kind order (query, mutation, command, object, inputObject, enumeration,
scalar), then name. `includeReferencedTypes` appends, after the direct matches, the
input types (arguments, transitively through input objects) and the result type (one
level: the result object and the named types of its fields) of matched operations,
deduplicated, `matchedOn: ["referenced-by:<operation>"]`. `limit` truncates after
ordering.

### 5. Document builder

`GatewayOperationRequest`, `GatewaySelection`, `GatewayDocumentBuilder`,
`GatewayBuiltDocument` exactly as master §2.3.

- Errors (`GatewaySDKError`, an enum with associated values and a `description`):
  `unknownOperation(name)`, `unknownVariable(operation, name)`,
  `missingRequiredVariable(operation, name)`, `invalidSelectionPath(path)`,
  `commandOperationNeedsArgv(name)`, `graphQLOperationNeedsDocument(name)`,
  `invalidPattern(String)`, `variableTypeMismatch(name, expected, actual)`.
- Document shape (exact):
  ```graphql
  query Threads($accountId: ID!, $first: Int) {
    threads(accountId: $accountId, first: $first) {
      totalCount
      pageInfo { hasNextPage endCursor }
      edges { cursor node { id subject ... } }
    }
  }
  ```
  Operation name = operation name upper-camel-cased. Only supplied variables are
  declared and passed. Mutations use `mutation`. Variables are returned as
  `[String: GatewayJSONValue]` untouched.
- Lightweight type check of supplied variables against the declared type: scalars
  (`ID`/`String` accept string; `Int` accepts int; `Float` accepts int or double;
  `Boolean` accepts bool; `JSON` accepts anything), enums accept a string that is one of
  the values, lists accept arrays (or a single value, auto-wrapped), input objects accept
  objects whose keys are declared input fields (unknown key = mismatch, missing required
  field = mismatch). `null` is accepted for non-required.
- Default selection per master §2.3 (depth 3, cycle stop by type name on the current path,
  skip fields with required arguments, scalars/enums/`JSON` are leaves). A result type
  that is a scalar prints no selection set. If a nested object would end up with an
  empty selection (all fields skipped), omit that field.
- `.fields([...])` accepts dot paths; a path to an object field without deeper paths
  expands to that object's default selection (depth counted from there). Paths are
  validated against the catalog (`invalidSelectionPath`).
- `.raw(String)` is used verbatim (must start with `{`).
- `GatewayArgvBuilder.build(_ request:, catalog:) throws -> [String]` for
  `kind == .command`: command name split on spaces followed by `--flag value` pairs in
  catalog argument order; `Boolean true` → bare `--flag`, `false` → omitted; lists →
  repeated flag; objects/arrays of objects → JSON string; required flags enforced;
  unknown variables rejected. Selection is ignored for commands.

### 6. Variable inliner (for gmail-gateway)

```swift
public struct GraphQLVariableInliner {
  public init(catalog: GatewaySchemaCatalog)
  public func inline(document: String, variables: [String: GatewayJSONValue]) throws -> String
}
```
- A small GraphQL lexer (`GraphQLToken`: punctuator, name, variable, int, float, string,
  blockString, comment; with source ranges). Public enough to test; may be `package` or
  `public`.
- Parses the leading operation definition: optional `query|mutation` keyword, optional
  name, optional `( $name: Type = default, ... )` variable definitions. Anonymous
  `{ ... }` documents with no variables pass through unchanged.
- Validation (wrike rules): every declared variable must be used at least once in the
  body; every `$var` used must be declared; every supplied variable must be declared
  (`unknownVariable`); a declared `Type!` variable without a supplied value and without a
  default is `missingRequiredVariable`; supplied values are type-checked like §5.
- Rewrite: the variable-definition parenthesis is removed (keeping `query Name`), and
  every `$var` token in the body is replaced by the GraphQL literal of its value: strings
  escaped per the GraphQL spec (`"`, `\`, control chars, unicode escapes), ints, floats,
  booleans, `null`, lists `[ ... ]`, objects `{ key: value }`, and enum-typed values
  rendered bare. Defaults apply when the variable is absent. Tokens inside strings /
  block strings / comments are never touched. Everything else (whitespace, comments,
  selection sets) is preserved byte-for-byte.
- Also expose `GraphQLLiteralRenderer.render(_ value:, as type: GatewayTypeRef?, catalog:)`
  used by the rewrite.

### 7. SDK protocol and envelope

`GatewayEnvelope`, `GatewayEnvelopeError { message, code: String?, path: [String]? }`,
and `protocol GatewaySDK` exactly as master §2.5 with default implementations for
`catalog`, `invoke`, `schemaSDL`, `searchSchema`. `GatewayEnvelope` gets
`init(parsingCLIOutput stdout: String, exitCode: Int32)` that understands the two
envelope shapes the gateways print today: `{data, errors: [{message,...}], extensions:
{requestId}}` and `{ok: Bool, data, error: {code, message}}`; unparsable output becomes
one error with the raw text.

## Tests (swift-testing)

- Fixture catalogs in `Tests/GatewaySDKKitTests/Fixtures/`: a GraphQL-style catalog
  modelled on gmail (`threads` connection with `edges/node/messages/from`, `sendMessage`
  with `SendMessageInput`, an enum `Direction`), and a command catalog modelled on
  google-documents (`values get`, `files list`, `files delete` with confirm flag).
- Catalog `validate()` positive and negative cases.
- SDL printing golden tests (stable order, block-string descriptions, `type Command`).
- Search: name / argument / field / enum-value / summary matches, ordering, kinds
  filter, `includeReferencedTypes`, `limit`, invalid regex.
- Builder: the exact document shape above, default-selection depth and cycle stop,
  skipping fields with required args, `.fields` paths (valid and invalid), `.raw`,
  required / unknown / type-mismatched variables, mutation keyword, command argv
  (bools, lists, objects, required, unknown).
- Inliner: passthrough of anonymous documents, all validation errors, literal rendering
  incl. escapes and unicode, `$` inside strings and comments untouched, defaults, enums
  bare, byte-preservation of the rest of the document.
- Envelope parsing of both CLI shapes and garbage.
- `GatewayJSONValue` round trips (`Any` ⇄ value ⇄ JSON string), bool-vs-number
  distinction, sorted keys.

## Verification

`arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gateway-sdk-kit && swift build && swift test && swiftlint'`
must be green. Keep files under 1000 lines (`.swiftlint.yml` thresholds apply). Update
`README.md` with a short API tour (catalog → search → build → invoke; inliner) and commit
on `main`.

## Non-goals

No networking, no credentials, no gateway-specific code, no dependencies, no CLI target.
