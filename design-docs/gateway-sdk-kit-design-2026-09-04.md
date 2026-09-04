# Design: GatewaySDKKit implementation (2026-09-04)

Source contracts:

- Package brief: `design-docs/briefs/gateway-sdk-kit-2026-09-04.md` (as amended by
  `fc9a30f`, which removed the `GatewaySDK` associated type).
- Master design §2: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`.

Where the brief extends the master design, the brief wins. Where the brief is silent,
the master §2 signatures apply verbatim. This document pins every decision the brief
leaves open so the golden tests define one deterministic contract for the five gateway
facades and riela.

## 1. Module layout (all files under 1000 lines, 2-space indent)

```
Sources/GatewaySDKKit/
  GatewaySDKKit.swift            (existing placeholder, unchanged)
  GatewayJSONValue.swift         JSON enum, init(any:), anyValue, parse, jsonString
  GatewaySDKError.swift          error enum + CustomStringConvertible
  GatewayTypeRef.swift           indirect enum, helpers, parse, custom Codable
  GatewayCatalogModel.swift      catalog, operation, argument, named type, field,
                                 definition kind, builtinScalars, lookups
  GatewayCatalogValidation.swift validate() + GatewaySchemaProblem
  GatewaySDLPrinter.swift        sdl(), sdlFragment(for:name:)
  GatewaySchemaSearch.swift      Options, Match, search
  GatewayDocumentBuilder.swift   request, selection, builder, built document
  GatewaySelectionPlanner.swift  default selection + .fields path expansion
  GatewayVariableTypeCheck.swift shared §5 variable type check
  GatewayArgvBuilder.swift       argv building for command catalogs
  GraphQLLexer.swift             GraphQLToken + tokenizer
  GraphQLVariableInliner.swift   operation-header parse, validation, splice rewrite
  GraphQLLiteralRenderer.swift   value -> GraphQL literal
  GatewayEnvelope.swift          envelope, error, CLI-output parsing, failure(_:)
  GatewaySDK.swift               protocol + default implementations

Tests/GatewaySDKKitTests/
  Fixtures/gmail-catalog.json
  Fixtures/documents-command-catalog.json
  FixtureCatalogs.swift          loading helpers (Bundle.module)
  GatewayJSONValueTests.swift
  CatalogValidationTests.swift
  TypeRefTests.swift
  SDLPrinterTests.swift
  SchemaSearchTests.swift
  DocumentBuilderTests.swift
  ArgvBuilderTests.swift
  GraphQLLexerTests.swift
  VariableInlinerTests.swift
  EnvelopeTests.swift
  GatewaySDKProtocolTests.swift
  GatewaySDKKitVersionTests.swift (existing, unchanged)
```

`Package.swift` change (pre-authorized): add `resources: [.copy("Fixtures")]` to the
test target. Nothing else.

## 2. GatewayJSONValue

Enum exactly as brief §1; conformances `Codable, Sendable, Equatable, Hashable`.

- `init(any:)` accepts: `NSNull`/`nil`-less null, `Bool`, `Int`, `Double`, `String`,
  `NSNumber`, `[Any]`, `[String: Any]` (and their NS bridges), plus `GatewayJSONValue`
  itself (identity). Anything else throws `GatewaySDKError.invalidJSONValue(String)`.
- NSNumber discrimination is Linux-safe: inspect `String(cString: number.objCType)`;
  `"c"`/`"B"` -> bool (JSONSerialization produces objCType "c" for booleans on both
  platforms; it never produces genuine Int8 numbers), integer codes
  (`i s l q C S L Q`) -> `.int` when representable in `Int` else `.double`,
  `f d` -> `.double`. Never use `is Bool` casts (Darwin bridging makes every NSNumber
  cast to Bool succeed) and never use CoreFoundation APIs (not exported on Linux).
- `anyValue`: inverse (`NSNull()`, `Bool`, `Int`, `Double`, `String`, `[Any]`,
  `[String: Any]`).
- `parse(_ json: String)`: `JSONSerialization.jsonObject(with:options:[.fragmentsAllowed])`
  then `init(any:)`; a non-UTF8-decodable or malformed string throws
  `GatewaySDKError.invalidJSON(String)` wrapping the underlying message.
- `jsonString(pretty:)`: hand-written serializer (not JSONSerialization) so key order
  is guaranteed: object keys sorted with `<` on String; pretty mode uses 2-space
  indentation, `": "` separators, newlines between elements; compact mode has no
  whitespace. String escaping: `\" \\ \n \r \t`, `\u00XX` for remaining C0 controls;
  all other characters raw UTF-8. Doubles render via `String(describing:)` (Swift
  shortest round-trip); ints via `String(_:)`.
- Codable: single-value container. Decode order: nil check, `Bool`, `Int`, `Double`,
  `String`, `[GatewayJSONValue]`, `[String: GatewayJSONValue]`. Encode symmetric.

## 3. Errors

```swift
public enum GatewaySDKError: Error, Sendable, Equatable, CustomStringConvertible {
  case unknownOperation(name: String)
  case unknownVariable(operation: String, name: String)
  case missingRequiredVariable(operation: String, name: String)
  case invalidSelectionPath(path: String)
  case commandOperationNeedsArgv(name: String)
  case graphQLOperationNeedsDocument(name: String)
  case invalidPattern(String)
  case variableTypeMismatch(name: String, expected: String, actual: String)
  // Additions required by features the brief's list does not cover:
  case unusedVariable(operation: String, name: String)     // inliner: declared-unused
  case undeclaredVariable(name: String)                    // inliner: used-undeclared
  case malformedDocument(String)                           // inliner/lexer parse failure
  case invalidTypeReference(String)                        // GatewayTypeRef.parse
  case invalidJSON(String)                                 // GatewayJSONValue.parse
  case invalidJSONValue(String)                            // GatewayJSONValue.init(any:)
}
```

The brief names the first eight; §6's declared-unused / used-undeclared rules and the
throwing `parse`/`init(any:)` APIs have no matching case, so the additions above are
part of the public contract. `description` is a one-line human message per case;
`variableTypeMismatch.expected` is the declared type's `graphQLString`, `actual` is a
short value-kind word (`"string"`, `"int"`, `"double"`, `"bool"`, `"null"`, `"array"`,
`"object"`).

## 4. Catalog model

Types exactly as master §2.2 (`GatewaySchemaCatalog`, `GatewayOperation` + `Kind`,
`GatewayArgument`, `GatewayTypeRef`, `GatewayNamedType` + `Kind`, `GatewayField`), all
`Codable, Sendable, Equatable`, memberwise `public init` with defaults for optional
fields. Plus per brief §2: `GatewayDefinitionKind: String, Codable, Sendable,
CaseIterable, Equatable, Hashable` (`query mutation command object inputObject
enumeration scalar`), `GatewaySchemaCatalog.builtinScalars: Set<String>` =
`ID String Int Float Boolean JSON`, and lookups `namedType(_:)`, `operation(named:)`,
`operations(of:)` (linear scans; catalogs are small).

Wire format decisions (fixtures and facades depend on these):

- `GatewayTypeRef` gets custom Codable encoding as its `graphQLString`
  (`"[Foo!]!"`) in a single-value container and decoding through
  `GatewayTypeRef.parse`. Helpers: `namedTypeName` (innermost name), `isRequired`
  (outermost is nonNull), `isList` (list anywhere after unwrapping outer nonNull),
  `graphQLString`, `static parse(_:)` — a recursive-descent parser over
  `name`, `[`, `]`, `!`; malformed input throws `.invalidTypeReference`.
- `GatewayNamedType.Kind` gets custom Codable:
  `{"kind":"scalar"}`, `{"kind":"object","fields":[...]}`,
  `{"kind":"inputObject","inputFields":[...]}`, `{"kind":"enumeration","values":[...]}`.
- Everything else uses synthesized Codable with the member names as keys.

### validate()

`GatewaySchemaProblem { public var path: String; public var message: String }`
(`Codable, Sendable, Equatable`). `path` is a dotted locator such as
`operation.threads.arguments.accountId`, `type.Thread.fields.subject`,
`operation.sendMessage.result`, `type.Direction`.

Checks (in deterministic catalog order, one problem per finding):

1. Unknown named-type references (not builtin, no `GatewayNamedType`): operation
   argument types, operation result types, object field types, object field argument
   types, input-object field types.
2. Duplicate operation names; duplicate type names (second and later occurrences
   reported).
3. Required argument (`isRequired == true` or outer nonNull on `type`) with a non-nil
   `defaultValue` — reported wherever arguments appear (operations, fields, input
   objects). `isRequired` disagreement with the type's outer nonNull is NOT a problem
   (the flag is authoritative for requiredness; kept as master defined it).
4. `kind == .query` or `.mutation` with `result == nil`; `.command` with non-nil
   result is allowed.
5. Enumeration with empty values; object with empty fields. (Input objects with no
   fields are allowed — not listed in the brief.)

## 5. SDL printer

`sdl()` prints, in this order, separated by single blank lines and ending with a
trailing newline:

1. custom scalars (`scalar X`), sorted by name;
2. enums, sorted by name; values one per line, 2-space indent;
3. input objects, sorted by name (`input Name { field: Type }` fields one per line);
4. objects, sorted by name (`type Name { ... }`);
5. `type Query` with one field per `.query` operation, in catalog operation order;
6. `type Mutation` likewise for `.mutation` (omitted when there are none);
7. `type Command` likewise for `.command` operations (omitted when none): one field
   per command whose arguments are the flags; result prints the operation's `result`
   when present, else `JSON`.

Field lines: `name(arg: Type!, other: [Int]): Result` — arguments inline, comma-space
separated, omitted parens when no arguments. Descriptions (type descriptions, field
descriptions, operation summaries when non-empty) print as `"""` block strings on the
line(s) above the definition, indented to match. Argument descriptions are not printed
(inline argument lists cannot carry block strings legibly).

SDL name sanitization (SDL output only; catalog values stay raw): command names and
flag names may contain spaces / dashes which are invalid GraphQL identifiers; the
printer maps every character outside `[_0-9A-Za-z]` to `_` (`"values get"` ->
`values_get`, `page-size` -> `page_size`).

`sdlFragment(for:name:)` returns exactly one definition: for type kinds the same text
as the corresponding `sdl()` block; for `.query`/`.mutation`/`.command` the enclosing
root type wrapped around the single field, e.g.
`type Query {\n  threads(accountId: ID!, first: Int): ThreadConnection\n}` (valid SDL
standalone). Returns nil when the name does not exist under that kind. No trailing
newline on fragments.

## 6. Schema search

Signatures exactly as master §2.4; `Options.kinds` default is
`[.query, .mutation, .command, .object, .inputObject, .enumeration]` (no `.scalar`),
`Match` is `Codable, Sendable, Equatable`.

- Pattern compiled once with `try Regex(pattern)`; failure -> `.invalidPattern` with
  the underlying message. Matching = `firstMatch != nil` (contains semantics);
  exactness = `wholeMatch(of:)` on the definition name.
- Candidate fields and `matchedOn` labels, collected in this order:
  `"name"`; operation arguments `argument:<n>`; object fields `field:<n>`; object
  field arguments `argument:<n>`; input-object fields `field:<n>`; enum values
  `value:<V>`; operation `summary` and type/field/argument `description` texts all
  under the single label `"summary"` (deduplicated).
- `tier` = operation tier for operations, nil for types. `sdl` = `sdlFragment`.
- Ordering: exact whole-name matches first (amongst themselves ordered by kind then
  name), then remaining matches by kind order
  (query, mutation, command, object, inputObject, enumeration, scalar) then by name.
- `includeReferencedTypes`: for each matched operation, collect (a) argument named
  types, expanding transitively through input objects (their input-field named
  types), and (b) the result's named type plus, one level down, the named types of
  that object's fields. Builtin scalars are never included; custom scalars are
  (referenced additions are not filtered by `options.kinds`). Deduplicate against
  direct matches and each other by (kind, name); a type referenced by several matched
  operations gets one entry with all `referenced-by:<operation>` labels, sorted.
  Appended after the direct matches, ordered by kind order then name.
- `limit` truncates the final combined list after ordering and appending.

## 7. Document builder

Types exactly as master §2.3. `GatewaySelection` is `Sendable, Equatable` (not
Codable, per master). `GatewayBuiltDocument { document: String; variables: [String:
GatewayJSONValue] }` is `Sendable, Equatable`.

`build(_:)` flow:

1. Look up operation; unknown -> `.unknownOperation`. `kind == .command` ->
   `.commandOperationNeedsArgv`.
2. Variables: supplied keys must be declared arguments (else `.unknownVariable`);
   every required argument must be supplied with a non-null value unless it has a
   `defaultValue` in the catalog (else `.missingRequiredVariable`); each supplied
   value type-checked (section 9). Only supplied variables are declared and passed;
   catalog defaults are NOT injected (the gateway applies its own defaults).
3. Selection built per section 8; scalar/enum result types produce no selection set.
4. Variables dictionary returned untouched (minus nothing — exactly what was
   supplied).

Rendering policy (the golden contract; matches the brief's example exactly):

```
query Threads($accountId: ID!, $first: Int) {
  threads(accountId: $accountId, first: $first) {
    totalCount
    pageInfo { hasNextPage endCursor }
    edges { cursor node { id subject } }
  }
}
```

- Line 1: `query|mutation` + space + operation name upper-camel-cased (split the
  catalog name on spaces/`-`/`_`, uppercase each fragment's first letter, join;
  `sendMessage` -> `SendMessage`, `files list` never reaches here). Variable
  declarations in catalog argument order filtered to supplied variables, as
  `($name: <graphQLString>)`; parens omitted entirely when no variables are supplied.
- Line 2 (2-space indent): root field with `(arg: $arg, ...)` for supplied variables
  in catalog order, parens omitted when none. If there is a selection set, ` {`.
- First-level selection entries: one per line, 4-space indent. A first-level entry
  with a nested selection renders the nested set inline single-line:
  `field { a b c { d } }` (single spaces, no commas).
- Closing `  }` then `}`. No trailing newline.
- `.raw(String)`: must start with `{` after trimming leading whitespace (else
  `.invalidSelectionPath(path: raw)`); appended verbatim after a single space on the
  root-field line: `  threads(first: $first) { id subject }`.

## 8. Selection planning

Default selection over the result object type:

- `plan(type, level)` starting at `level 0` for the result object; include every
  scalar / enum / builtin-scalar (`JSON` included) field; skip any field that has one
  or more required arguments; for an object (or list-of-object) field: recurse only
  when `level < 3` AND the field's named type is not already on the current type path
  (the path includes the result root type); include the field only when the recursion
  returns a non-empty selection. So the root's object fields open selections at
  levels 1..3 and an object field that would open level 4 is omitted, as is any
  object whose fields were all skipped.
- List wrappers are transparent (recursion identical).

`.fields([...])` dot paths:

- Each path is split on `.`; segments are resolved against the result object type,
  descending through object/list-of-object fields. Unknown segment, a segment that
  descends through a scalar/enum, a path through a field with required arguments, or
  an empty path/segment -> `.invalidSelectionPath(path:)` carrying the full original
  path string.
- Paths merge into one selection tree. A leaf segment naming a scalar/enum field is a
  leaf. A leaf segment naming an object field with no deeper paths expands to that
  object's default selection with depth counted from there (`plan(objectType, 0)`,
  cycle path seeded with the types walked so far).
- Rendering: first-level entries in first-appearance order of the paths, one per
  line; nested levels inline, as in section 7.

## 9. Variable type check (shared by builder, argv builder, inliner)

`check(value, against typeRef)` unwrapping nonNull:

- `null`: accepted iff the type is not required (outer nonNull rejects null).
- Scalars: `ID`/`String` accept `.string`; `Int` accepts `.int`; `Float` accepts
  `.int` or `.double`; `Boolean` accepts `.bool`; `JSON` accepts anything (including
  null when not required).
- Enum type: accepts `.string` whose value is one of the enum's values.
- List type: accepts `.array` (elements checked against the element type) or a single
  non-array value, auto-wrapped and checked against the element type.
- Input object type: accepts `.object`; unknown key -> mismatch; each present key
  checked recursively; a required input field (nonNull type, no default) missing ->
  mismatch.
- Unknown named type (should not survive `validate()`): mismatch.

Failure throws `.variableTypeMismatch(name:expected:actual:)` with the outermost
variable's name.

## 10. Argv builder

`GatewayArgvBuilder.build(_ request:, catalog:) throws -> [String]`:

1. Operation lookup: unknown -> `.unknownOperation`; kind != `.command` ->
   `.graphQLOperationNeedsDocument`.
2. Supplied keys must be declared flags (`.unknownVariable`); required flags must be
   supplied non-null (`.missingRequiredVariable`; catalog defaults are not injected);
   values type-checked per section 9.
3. Output: the command name split on spaces (`"values get"` -> `["values", "get"]`),
   then for each catalog argument in declaration order that was supplied:
   - `Boolean`: `true` -> bare `--flag`; `false` -> omitted entirely.
   - list: the flag repeats per element (`--id a --id b`); element rendering as
     below; a list of objects renders each element as compact JSON.
   - `.object` (or auto-wrapped arrays of objects): compact sorted-key JSON string.
   - `.string` -> the string as-is; `.int`/`.double` -> decimal rendering; `null`
     (non-required) -> omitted.
4. Selection is ignored for commands.

## 11. GraphQL lexer

```swift
public struct GraphQLToken: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case punctuator, name, variable, int, float, string, blockString, comment
  }
  public var kind: Kind
  public var text: String            // raw source slice, including quotes/# for value tokens
  public var range: Range<String.Index>
}
```

`GraphQLLexer.tokenize(_ source: String) throws -> [GraphQLToken]` (public — the five
consumers' tests may use it). Per the GraphQL spec: whitespace, commas and BOM are
ignored (not tokens); `#` comments run to end of line (kept as `.comment` tokens);
strings support `\" \\ \/ \b \f \n \r \t \uXXXX`; block strings `"""..."""` support
`\"""`; `$name` lexes as one `.variable` token (text includes `$`); names
`[_A-Za-z][_0-9A-Za-z]*`; int/float per spec (`-?digits(.digits)?((e|E)(+|-)?digits)?`,
float iff fraction or exponent present); every other legal punctuator (`! ( ) ... : =
@ [ ] { } | &`) is a one-token `.punctuator` (`...` is a single token). Unterminated
string/block string or an illegal character throws `.malformedDocument` naming the
offset. Variable and dollar characters inside `.string`/`.blockString`/`.comment`
tokens are inert by construction.

## 12. Variable inliner

`GraphQLVariableInliner(catalog:)`, `inline(document:variables:) throws -> String`.

1. Tokenize. Skip leading comments. First significant token:
   - `{` punctuator -> anonymous operation. If the body contains any `.variable`
     token -> `.undeclaredVariable`; if `variables` is non-empty -> `.unknownVariable`
     (operation `"(anonymous)"`) for the first supplied name (sorted); otherwise
     return `document` unchanged (byte-identical).
   - name `query` or `mutation` -> parse optional name token, then optional variable
     definitions. Any other first token (including `subscription`) ->
     `.malformedDocument`.
2. Variable definitions `( $a: Type = default, ... )`: for each — `.variable` token,
   `:` punctuator, a type (name / `[` type `]` with optional `!`s) parsed into
   `GatewayTypeRef`, optional `= <const value>` parsed into `GatewayJSONValue` (int,
   float, string, `true|false|null`, enum names as `.string`, const lists and
   objects; a `$` inside a default -> `.malformedDocument`). Duplicate declaration
   -> `.malformedDocument`. Record the exact source range from `(` through `)`.
3. Validation (operation label = parsed name or `"(anonymous)"`):
   - supplied key not declared -> `.unknownVariable`;
   - declared variable with no `.variable` occurrence in the body ->
     `.unusedVariable`;
   - `.variable` token in the body not declared -> `.undeclaredVariable`;
   - declared required (outer `!`), no supplied value (or supplied null) and no
     default -> `.missingRequiredVariable`;
   - each supplied value type-checked per section 9 against the declared type
     (named types resolved against the catalog; a declared type name that is neither
     builtin nor in the catalog type-checks only `JSON`-style as mismatch).
4. Rewrite by splicing the original string (single pass, ranges ascending):
   - the recorded `(`..`)` range is deleted (whitespace before `(` and after `)` is
     preserved, so `query Threads($a: ID!) {` becomes `query Threads {`);
   - every body `.variable` token range is replaced by
     `GraphQLLiteralRenderer.render(value, as: declaredType, catalog:)` where value =
     supplied ?? declared default;
   - everything else — whitespace, comments, strings, block strings, selection sets —
     is preserved byte-for-byte.

## 13. Literal renderer

`GraphQLLiteralRenderer.render(_ value: GatewayJSONValue, as type: GatewayTypeRef?,
catalog: GatewaySchemaCatalog) -> String`:

- nonNull unwraps; `null` -> `null`; `.bool` -> `true`/`false`; `.int` -> decimal;
  `.double` -> `String(describing:)` (shortest round-trip; exponent forms are valid
  GraphQL floats).
- `.string`: if the declared type (after unwrapping) resolves to an enumeration in
  the catalog, render bare (`ROWS`); otherwise a quoted GraphQL string with escapes
  `\"` `\\` `\n` `\r` `\t` `\b` `\f`, `\u00XX` for remaining C0 controls, all other
  characters (including non-ASCII) raw.
- `.array` -> `[e1, e2]` with elements rendered against the list's element type; a
  non-array value against a list type renders as the bare element (GraphQL coerces).
- `.object` -> `{key: value}` with keys bare and sorted, values rendered against the
  matching input-field type when the declared type is a known input object (else no
  type context).

## 14. Envelope and protocol

```swift
public struct GatewayEnvelopeError: Codable, Sendable, Equatable {
  public var message: String
  public var code: String?
  public var path: [String]?
}
public struct GatewayEnvelope: Codable, Sendable, Equatable {
  public var data: GatewayJSONValue?
  public var errors: [GatewayEnvelopeError]
  public var requestId: String?
  public var exitCode: Int32
  public var rawOutput: String
}
```

`init(parsingCLIOutput stdout: String, exitCode: Int32)` (non-throwing):

- Parse stdout as JSON. On failure, or when the JSON is not an object, or an object
  with neither an `ok` bool nor a `data`/`errors` key: `data = nil`, `errors = [one
  error whose message is stdout verbatim]`, `requestId = nil`.
- Shape B `{ok: Bool, data, error: {code, message}}` (detected by an `ok` bool key):
  `data` = the `data` member (nil when absent/null); when `ok` is false or `error`
  is present, one `GatewayEnvelopeError(message: error.message ?? "unknown error",
  code: error.code)`.
- Shape A `{data, errors: [{message, ...}], extensions: {requestId}}`: `data`
  likewise; each errors element -> message (`"unknown error"` when missing), `code`
  from `code` or `extensions.code` when a string, `path` from a `path` array with
  elements stringified (ints included); `requestId` from top-level
  `extensions.requestId` when a string.
- Always: `rawOutput = stdout`, `exitCode` as given.

`static func failure(_ error: Error, exitCode: Int32) -> GatewayEnvelope`: one error
whose message is the error's `description` (via `CustomStringConvertible` when
available, else `String(describing:)`), `data = nil`, `rawOutput = ""`.

Protocol exactly as the amended brief §7 (no associated type):

```swift
public protocol GatewaySDK: Sendable {
  var provider: String { get }
  var tier: String { get }
  var catalog: GatewaySchemaCatalog { get }
  func execute(document: String, variables: [String: GatewayJSONValue], environment: [String: String]) async -> GatewayEnvelope
  func invoke(_ request: GatewayOperationRequest, environment: [String: String]) async -> GatewayEnvelope
  func schemaSDL() -> String
  func searchSchema(_ pattern: String, options: GatewaySchemaSearch.Options) throws -> [GatewaySchemaSearch.Match]
}
```

Default implementations (protocol extension): `schemaSDL()` = `catalog.sdl()`;
`searchSchema` = `GatewaySchemaSearch(catalog: catalog).search(...)`; `invoke` looks
the operation up — `.command` builds argv via `GatewayArgvBuilder` and calls
`execute(document: <compact JSON-encoded argv array>, variables: [:], ...)`;
query/mutation builds via `GatewayDocumentBuilder` and calls `execute(document:
built.document, variables: built.variables, ...)`; any thrown builder error returns
`GatewayEnvelope.failure(error, exitCode: 2)`.

## 15. Fixtures

`Fixtures/gmail-catalog.json` (provider `gmail-gateway`, tier `reader`): queries
`threads` (args `accountId: ID!` required, `first: Int`), `thread(accountId: ID!,
id: ID!)`; mutation `sendMessage(accountId: ID!, input: SendMessageInput!)` returning
`SendMessagePayload`; types `ThreadConnection { totalCount pageInfo edges }`,
`PageInfo { hasNextPage endCursor }`, `ThreadEdge { cursor node }`, `Thread { id
subject messages }`, `Message { id snippet direction from }` (a field with a required
argument, e.g. `raw(format: String!): String`, to exercise skipping), `EmailAddress
{ address name }` (level-4 omission target), `SendMessageInput` (required `to:
[String!]!`, optional `subject: String`, `direction: Direction`), `SendMessagePayload
{ id }`, enum `Direction { INBOUND OUTBOUND }`, and a custom scalar to exercise SDL.
Descriptions/summaries present on a few items for search/SDL tests. The `Thread ->
Message -> Thread` style cycle is exercised by giving `Message` a `thread: Thread`
field.

`Fixtures/documents-command-catalog.json` (provider `google-documents-gateway`, tier
`writer`): commands `values get` (`spreadsheet-id: ID!` required, `range: String!`,
`major-dimension: Dimension` enum), `files list` (`query: String`, `page-size: Int`,
`drive-id: ID`, `fields: [String]` list), `files delete` (`file-id: ID!`, `confirm:
Boolean` bare-flag case), plus an object-typed flag (e.g. `value-input: ValueInput`
input object) to exercise JSON-string flags.

Both load via `Bundle.module` + `JSONDecoder` (this also regression-tests the wire
format) and must satisfy `validate() == []`.

## 16. Test strategy

swift-testing throughout (`@Test`, `#expect`, `#expect(throws:)`), one suite file per
area (section 1), every brief Tests bullet mapped:

- JSON value: `Any` -> value -> `Any` -> value round trip via JSONSerialization
  output; value -> `jsonString` -> `parse` round trip; NSNumber bool vs 1 vs 1.0
  discrimination; sorted-keys golden (`{"a":1,"b":2}` from unordered input); pretty
  output golden; Hashable sanity.
- validate(): both fixtures -> `[]`; one negative catalog per rule asserting the
  problem's `path` and message substring.
- TypeRef: `parse`/`graphQLString` round trips (`ID`, `[Int]`, `[Foo!]!`,
  `[[X]!]`), helper flags, malformed inputs throw.
- SDL: full-catalog golden strings for both fixtures (stable order, block-string
  descriptions, `type Command`, sanitized names); `sdlFragment` per kind + nil for
  unknown.
- Search: each matchedOn label kind; exact-name-first ordering vs substring match;
  kind-order tie break; kinds filter; `includeReferencedTypes` (transitive input
  expansion, one-level result expansion, dedup, referenced-by labels); `limit`;
  invalid regex -> `.invalidPattern`.
- Builder: byte-exact golden for the brief's `Threads` document; only-supplied
  variable declaration; mutation keyword; scalar-result no selection set; default
  selection depth boundary (level-3 object included, level-4 omitted) and cycle stop;
  required-arg field skipped; `.fields` valid paths incl. object-leaf default
  expansion, each invalid-path variant; `.raw` verbatim + non-`{` rejection; each
  error case (`unknownOperation`, `unknownVariable`, `missingRequiredVariable`,
  `variableTypeMismatch` for every §9 rule incl. list auto-wrap and input-object
  unknown-key/missing-required, `commandOperationNeedsArgv`).
- Argv: golden argv arrays (bool true/false, repeated list flags, JSON object flag,
  argument ordering), required missing, unknown variable, GraphQL op ->
  `graphQLOperationNeedsDocument`, selection ignored.
- Lexer: token kinds/ranges golden on a small document with comments, strings with
  escapes, block strings, floats; unterminated string throws.
- Inliner: anonymous passthrough byte-identical; each validation error
  (declared-unused, used-undeclared, unknown supplied, required missing, each
  type-mismatch rule); rendering goldens (string escapes incl. `` and raw
  non-ASCII, bare enums, lists, objects, defaults applied, null); `$var`-looking text
  inside strings/block strings/comments untouched; whitespace/comment
  byte-preservation asserted by full-document equality.
- Envelope: shape A with errors+extensions.requestId, shape A data-only, shape B ok
  true/false, garbage text, empty string, `failure(_:)`.
- Protocol: a test double conforming with only `provider`/`tier`/`catalog`/`execute`
  recording its inputs; assert default `invoke` sends the built document/variables,
  argv JSON for a command catalog, and a failure envelope (exit code 2) for builder
  errors; `schemaSDL`/`searchSchema` defaults delegate.

Verification gate (acceptance): `arch -arm64 /bin/zsh -lc 'cd
/Users/taco/gits/tacogips/gateway-sdk-kit && swift build && swift test && swiftlint'`
green, zero lint violations, every file < 1000 lines.

## 17. Rollout / compatibility

- Commit on `main` as work lands, focused messages, no AI attribution, no push/tags.
  Suggested sequence: (1) JSON value + errors (+tests), (2) type ref + catalog model
  + validate (+fixtures +tests), (3) SDL printer, (4) search, (5) document builder +
  selection planner + type check + argv, (6) lexer + inliner + literal renderer,
  (7) envelope + protocol, (8) README tour + impl-plan doc. Each commit builds and
  tests green.
- Public surface is the contract for five facades and riela: no renames from the
  brief; additions (error cases, lexer publicity, wire formats) are recorded here.
- README gains a short tour: build a catalog -> validate -> sdl/search -> build a
  document / argv -> invoke through GatewaySDK; separate inliner example.
- No networking, credentials, gateway code, or new dependencies; Linux cleanliness by
  construction (no CoreFoundation, no Darwin-only APIs, objCType-based NSNumber
  discrimination).
