# Implementation plan: GatewaySDKKit (2026-09-04)

Contracts (read in this order before writing code):

1. `design-docs/gateway-sdk-kit-design-2026-09-04.md` — the pinned design. Every
   rendering rule, wire format, error case, and edge case is decided there; do not
   re-decide anything, and do not deviate without recording why.
2. `design-docs/briefs/gateway-sdk-kit-2026-09-04.md` — the package brief as amended
   by commit `fc9a30f` (GatewaySDK protocol has NO associated type).
3. Master design §2: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`
   (read-only; do not modify anything outside this repository).

Applicable prior knowledge: knowledge-base recall for `gateway-sdk-kit` returned zero
results; there is no prior knowledge to apply.

Ground rules (from workflow constraints and AGENTS.md):

- ONE feature; no fan-out. Zero dependencies, Foundation only, Linux-clean (no
  CoreFoundation, no Darwin-only APIs, no `is Bool` NSNumber checks). Swift 6 mode.
- Every public type `Sendable`; model types `Codable` + `Equatable`. Keep the
  existing `GatewaySDKKitVersion` placeholder and its test untouched.
- Every Swift file < 1000 lines, 2-space indent, swiftlint clean (`.swiftlint.yml`).
- Build/test through an arm64 shell:
  `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gateway-sdk-kit && swift build && swift test && swiftlint'`.
- Commit on `main` after each task once green; focused messages; NO AI attribution
  or co-authorship lines; do not push; no tags.
- `Package.swift` may change only to add `resources: [.copy("Fixtures")]` to the
  test target (task 2).

## Task order

Each task = implement + tests + verify + commit. Suggested commit messages included.

### Task 1 — JSON value and errors

Files: `Sources/GatewaySDKKit/GatewayJSONValue.swift`,
`Sources/GatewaySDKKit/GatewaySDKError.swift`,
`Tests/GatewaySDKKitTests/GatewayJSONValueTests.swift`.

- `GatewayJSONValue` per design §2: cases null/bool/int/double/string/array/object;
  `Codable` via single-value container (decode order: nil, Bool, Int, Double, String,
  array, object), `Sendable, Equatable, Hashable`.
- `init(any:)`: NSNull, Bool, Int, Double, String, NSNumber (objCType-string
  discrimination: `"c"`/`"B"` bool; `i s l q C S L Q` int with Int-representable
  check else double; `f d` double), `[Any]`, `[String: Any]`, `GatewayJSONValue`
  identity; else throw `.invalidJSONValue`.
- `anyValue` inverse; `parse(_:)` via JSONSerialization `.fragmentsAllowed` then
  `init(any:)` (failure -> `.invalidJSON`); `jsonString(pretty:)` via the
  hand-written serializer: sorted object keys, escapes `\" \\ \n \r \t` +
  `\u00XX` for other C0 controls, doubles via `String(describing:)`, pretty = 2-space
  indent + `": "` + newlines, compact = no whitespace.
- `GatewaySDKError` with ALL 14 cases from design §3 (brief's 8 + unusedVariable,
  undeclaredVariable, malformedDocument, invalidTypeReference, invalidJSON,
  invalidJSONValue), `Equatable`, `CustomStringConvertible` one-line messages.
- Tests: Any→value→Any→value round trip on JSONSerialization output; value→
  jsonString→parse round trip; `NSNumber(value: 1)` vs `true` vs `1.0`
  discrimination (build the Any via `JSONSerialization.jsonObject` on
  `{"b":true,"i":1,"d":1.0}` to get real bridged numbers); sorted-keys golden;
  pretty golden; Hashable set membership sanity.

Commit: `feat: add GatewayJSONValue and GatewaySDKError`

### Task 2 — Type ref, catalog model, validation, fixtures

Files: `Sources/GatewaySDKKit/GatewayTypeRef.swift`,
`Sources/GatewaySDKKit/GatewayCatalogModel.swift`,
`Sources/GatewaySDKKit/GatewayCatalogValidation.swift`,
`Tests/GatewaySDKKitTests/Fixtures/gmail-catalog.json`,
`Tests/GatewaySDKKitTests/Fixtures/documents-command-catalog.json`,
`Tests/GatewaySDKKitTests/FixtureCatalogs.swift`,
`Tests/GatewaySDKKitTests/TypeRefTests.swift`,
`Tests/GatewaySDKKitTests/CatalogValidationTests.swift`; `Package.swift` gains
`resources: [.copy("Fixtures")]` on the test target (the only allowed change).

- `GatewayTypeRef` indirect enum + helpers `namedTypeName`, `isRequired` (outer
  nonNull), `isList` (list after unwrapping outer nonNull), `graphQLString`,
  `static parse(_:)` (recursive descent over name/`[`/`]`/`!`; malformed ->
  `.invalidTypeReference`); custom Codable = single-value graphQLString.
- Model types per master §2.2 with memberwise public inits (defaults for optionals):
  `GatewaySchemaCatalog`, `GatewayOperation` (+`Kind` raw-string), `GatewayArgument`,
  `GatewayNamedType` (+`Kind` with custom Codable
  `{"kind":"object","fields":[...]}` / `inputFields` / `values` / bare scalar),
  `GatewayField`. Plus `GatewayDefinitionKind` (7 raw-string cases, CaseIterable),
  `builtinScalars`, `namedType(_:)`, `operation(named:)`, `operations(of:)`.
- `validate()` + `GatewaySchemaProblem{path,message}` per design §4: unknown type
  refs (operation args, operation results, object fields, object field args, input
  fields); duplicate operation/type names; required argument with defaultValue
  (everywhere arguments appear); query/mutation with nil result; empty enum; empty
  object. Dotted `path` locators exactly as design §4.
- Fixtures per design §15: gmail catalog (threads/thread queries, sendMessage
  mutation, ThreadConnection/PageInfo/ThreadEdge/Thread/Message/EmailAddress,
  `Message.raw(format: String!)` required-arg field, `Message.thread: Thread` cycle,
  SendMessageInput with required `to: [String!]!`, SendMessagePayload, enum
  Direction, one custom scalar, several descriptions/summaries); documents command
  catalog (`values get`, `files list` with list flag, `files delete` with confirm
  Boolean, one input-object flag, enum Dimension).
- Tests: fixture decode via `Bundle.module` + JSONDecoder; `validate() == []` for
  both fixtures; one negative catalog per rule asserting the problem `path`;
  TypeRef parse/graphQLString round trips (`ID`, `[Int]`, `[Foo!]!`, `[[X]!]`),
  helper flags, malformed parse throws; encode/decode round trip of a whole catalog
  (wire-format regression).

Commit: `feat: add the neutral schema catalog model, validation, and fixtures`

### Task 3 — SDL printer

Files: `Sources/GatewaySDKKit/GatewaySDLPrinter.swift`,
`Tests/GatewaySDKKitTests/SDLPrinterTests.swift`.

- `sdl()` per design §5: group order scalars/enums/inputs/objects/Query/Mutation
  (omit empty)/Command (omit empty); types name-sorted within group, root fields in
  catalog operation order; single blank line between definitions, trailing newline
  at end; field lines `name(arg: Type!, ...): Result` (parens omitted when no
  args); command results default to `JSON`; `"""` block-string descriptions above
  definitions (types, fields, operations), argument descriptions not printed;
  SDL-only sanitization of non-`[_0-9A-Za-z]` chars to `_` in command/flag names.
- `sdlFragment(for:name:)`: exact single definition; root-field kinds wrapped as
  `type Query {\n  field...\n}`; nil for unknown; no trailing newline.
- Tests: full-catalog golden strings for BOTH fixtures (write goldens by hand from
  the design rules, then make the printer match); fragment per kind; nil fragment;
  empty-Mutation omission (derive a small catalog in-test).

Commit: `feat: add the SDL printer`

### Task 4 — Schema search

Files: `Sources/GatewaySDKKit/GatewaySchemaSearch.swift`,
`Tests/GatewaySDKKitTests/SchemaSearchTests.swift`.

- Per design §6. `Options` defaults: kinds without `.scalar`,
  `includeReferencedTypes = false`, `limit = nil`. `Match: Codable, Sendable,
  Equatable`. `try Regex(pattern)` -> `.invalidPattern` on failure. Contains
  semantics via `firstMatch`; exactness via `wholeMatch` on the name. matchedOn
  collection order: name, argument:<n>, field:<n> (object fields, then their
  argument:<n>), field:<n> for input fields, value:<V>, "summary" (operation
  summary + descriptions, deduplicated). tier = operation tier / nil for types.
  sdl = sdlFragment. Ordering: exact-name matches (kind order then name), then
  kind order (query, mutation, command, object, inputObject, enumeration, scalar)
  then name. Referenced types: matched operations only; args transitively through
  input objects; result type + one level of its fields' named types; never builtin
  scalars; not filtered by options.kinds; dedup by (kind,name) with merged sorted
  `referenced-by:<op>` labels; appended after direct matches ordered kind-then-name.
  `limit` truncates last.
- Tests per design §16 search bullet, driven by the gmail fixture (plus command
  kind via the documents fixture): every matchedOn label kind; exact-vs-substring
  ordering; kinds filter; referenced-types expansion incl. transitive input and
  dedup/merged labels; limit; invalid regex.

Commit: `feat: add regex schema search`

### Task 5 — Document builder, selection planner, type check, argv builder

Files: `Sources/GatewaySDKKit/GatewayDocumentBuilder.swift`,
`Sources/GatewaySDKKit/GatewaySelectionPlanner.swift`,
`Sources/GatewaySDKKit/GatewayVariableTypeCheck.swift`,
`Sources/GatewaySDKKit/GatewayArgvBuilder.swift`,
`Tests/GatewaySDKKitTests/DocumentBuilderTests.swift`,
`Tests/GatewaySDKKitTests/ArgvBuilderTests.swift`.

- `GatewayOperationRequest` (public memberwise init, `selection` default
  `.default`), `GatewaySelection` (`Sendable, Equatable`, NOT Codable),
  `GatewayBuiltDocument` (`Sendable, Equatable`), `GatewayDocumentBuilder` per
  design §7; rendering policy byte-exact per design §7 (2/4-space indents, inline
  nested selections, parens omitted when empty, no trailing newline, `.raw`
  appended verbatim after one space and must start with `{` after trimming leading
  whitespace). UpperCamelCase operation name (split on space/`-`/`_`). Catalog
  defaults NOT injected; only supplied variables declared/passed, catalog argument
  order.
- Selection planner per design §8: `plan(type, level)` from level 0; skip
  required-arg fields; object recursion iff level < 3 and no cycle (path includes
  root result type); omit empty; list wrappers transparent. `.fields` dot-path
  resolution + merge + object-leaf default expansion (depth recounted, cycle path
  seeded with walked types); every invalid variant -> `.invalidSelectionPath` with
  the full original path.
- Shared type check per design §9 (used by builder, argv, inliner) throwing
  `.variableTypeMismatch(name: <outer variable>, expected: graphQLString,
  actual: value-kind word)`.
- `GatewayArgvBuilder.build(_:catalog:)` per design §10: kind guard
  (`.graphQLOperationNeedsDocument` for query/mutation, `.unknownOperation`),
  unknown/required variable checks (no default injection), command name split on
  spaces, catalog argument order, bool true bare / false omitted, lists repeat the
  flag, objects (and object list elements) as compact sorted-key JSON, null
  non-required omitted, selection ignored.
- Tests: byte-exact golden for the brief's `Threads` document (accountId + first
  supplied); only-supplied declarations; mutation keyword golden (`sendMessage`);
  no-variables document (no parens); depth boundary (messages at level 3 opens,
  `from`/`thread` at level 4 omitted; cycle stop via Message.thread);
  required-arg skip (Message.raw absent); `.fields` valid (scalar leaf, deep path,
  object-leaf expansion) and each invalid variant; `.raw` verbatim + non-`{`
  rejection; every builder error case incl. the full §9 mismatch matrix (list
  auto-wrap, input-object unknown key / missing required, Float←int, JSON←anything,
  null rules); command op through the document builder ->
  `.commandOperationNeedsArgv`. Argv: golden arrays for the three fixture commands
  (ordering, bool true/false, repeated list flag, JSON object flag), required
  missing, unknown variable, GraphQL op rejection.

Commit: `feat: add the document builder, default selection, and argv builder`

### Task 6 — Lexer, literal renderer, variable inliner

Files: `Sources/GatewaySDKKit/GraphQLLexer.swift`,
`Sources/GatewaySDKKit/GraphQLLiteralRenderer.swift`,
`Sources/GatewaySDKKit/GraphQLVariableInliner.swift`,
`Tests/GatewaySDKKitTests/GraphQLLexerTests.swift`,
`Tests/GatewaySDKKitTests/VariableInlinerTests.swift`.

- Lexer per design §11: public `GraphQLToken{kind,text,range}` with
  `Range<String.Index>` over the ORIGINAL string; whitespace/commas/BOM skipped;
  `#` comments to EOL kept as tokens; strings with all spec escapes; block strings
  with `\"""`; `$name` one `.variable` token; int/float per GraphQL grammar; `...`
  one punctuator; unterminated string / illegal char -> `.malformedDocument`.
- Renderer per design §13 (enum-typed strings bare via catalog resolution, GraphQL
  escaping with `\u00XX` C0 fallback and raw non-ASCII, doubles shortest
  round-trip, arrays per element type with single-value coercion, objects bare
  sorted keys with input-field type context).
- Inliner per design §12: tokenize; leading comments skipped; anonymous `{` doc:
  body variable -> `.undeclaredVariable`, supplied non-empty -> `.unknownVariable`
  (operation "(anonymous)", first sorted name), else return input unchanged;
  `query|mutation` header only (else `.malformedDocument`, incl. subscription);
  variable-definition parse (type -> GatewayTypeRef, const default ->
  GatewayJSONValue, `$` in default / duplicate declaration ->
  `.malformedDocument`); validation order: unknown supplied, unused declared,
  undeclared used, missing required (supplied null counts as missing when no
  default), §9 type check; splice rewrite: delete exact `(`..`)` range, replace
  each body `.variable` token with rendered literal (value = supplied ?? default),
  everything else byte-preserved.
- Tests: lexer token kind/text/range goldens incl. block string and float;
  unterminated string throws. Inliner: anonymous passthrough byte-identical
  (compare full strings); each of the five wrike validation rules; escapes golden
  (`"a\"b\\c\nd"` + a C0 control -> `` + raw Japanese/emoji text); bare
  enum; list and input-object literals; default applied when absent; supplied
  overrides default; `$var`-lookalikes inside a string, a block string, and a
  comment untouched; full-document equality asserting whitespace/comment
  preservation (multi-line doc with comments and odd spacing).

Commit: `feat: add the GraphQL lexer, literal renderer, and variable inliner`

### Task 7 — Envelope and GatewaySDK protocol

Files: `Sources/GatewaySDKKit/GatewayEnvelope.swift`,
`Sources/GatewaySDKKit/GatewaySDK.swift`,
`Tests/GatewaySDKKitTests/EnvelopeTests.swift`,
`Tests/GatewaySDKKitTests/GatewaySDKProtocolTests.swift`.

- Per design §14. Envelope + error structs Codable/Sendable/Equatable with public
  memberwise inits. `init(parsingCLIOutput:exitCode:)` non-throwing: shape B on
  `ok` bool key; shape A on data/errors keys (code from `code` or
  `extensions.code`, path elements stringified, requestId from
  `extensions.requestId`); everything else -> one error with stdout verbatim;
  rawOutput always stdout. `static failure(_:exitCode:)`.
- Protocol exactly as amended brief §7 (provider/tier/catalog/execute/invoke/
  schemaSDL/searchSchema); extension defaults: schemaSDL, searchSchema, invoke
  (command -> GatewayArgvBuilder -> execute with compact-JSON argv document and
  empty variables; query/mutation -> GatewayDocumentBuilder -> execute; thrown
  errors -> `GatewayEnvelope.failure(error, exitCode: 2)`).
- Tests: shape A full (errors + extensions.requestId + path), shape A data-only,
  shape B ok:true, shape B ok:false (with and without error object), garbage text,
  empty string, non-object JSON; failure(_:). Protocol: recording test double
  (provider/tier/catalog/execute only) asserting default invoke passes the built
  document+variables, JSON argv for a command catalog, failure envelope exit code
  2 on builder error; schemaSDL/searchSchema delegate.

Commit: `feat: add GatewayEnvelope and the GatewaySDK protocol`

### Task 8 — README tour and final sweep

Files: `README.md`.

- README: keep the existing intro; add a short API tour — build/decode a catalog,
  validate, sdl + search, build a document (default selection) and argv, conform a
  minimal SDK + invoke, inliner example — with compact code snippets that match
  the actual API (compile-check them mentally against the final surface; they are
  documentation, not doctests).
- Final sweep: `wc -l Sources/GatewaySDKKit/*.swift Tests/GatewaySDKKitTests/*.swift`
  all < 1000; full gate command; `git status` clean after commit.

Commit: `docs: add the README API tour`

(The design doc `design-docs/gateway-sdk-kit-design-2026-09-04.md` and this plan
`impl-plans/gateway-sdk-kit-impl-plan-2026-09-04.md` are uncommitted in the
worktree; commit them FIRST, before task 1:
`docs: add the implementation design and plan`.)

## Dependencies

- Task 1 has no dependencies. Task 2 depends on 1 (errors, JSON value in
  defaultValue). Tasks 3 and 4 depend on 2 (4 also on 3 for sdlFragment). Task 5
  depends on 2 (+1 for type check values). Task 6 depends on 2 and 5 (shared type
  check). Task 7 depends on 4 and 5 (defaults). Task 8 depends on all.
- Within the sequence, tasks 3+4 and 5 touch disjoint files and could be developed
  in parallel, as could 6 vs 7 (except the shared type check); the commit order
  above keeps every commit green and is the recommended serial order.

## Verification

- After every task: `arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/gateway-sdk-kit && swift build && swift test && swiftlint'`.
- swiftlint must report zero violations (warnings included).
- Final: full gate green; all files < 1000 lines; `git log` shows focused commits
  on main, none pushed; `git status` clean; nothing outside the repo modified.

## Completion criteria

1. Full gate command green (build, all tests, lint zero violations).
2. All public API items of brief §1–§7 (amended) exist with exact names; placeholder
   `GatewaySDKKitVersion` untouched; no new dependencies/products; Package.swift
   changed only for test resources.
3. Both fixture catalogs decode and validate to `[]`; every negative validate case,
   every GatewaySDKError case, every §9 type-check rule, all five inliner rules,
   both envelope shapes + garbage, and all golden documents/SDL/argv covered by
   tests; brief's Tests section fully mapped.
4. README documents the API with the tour; design doc and this plan committed.
5. Every commit on main, focused, no AI attribution, nothing pushed.
