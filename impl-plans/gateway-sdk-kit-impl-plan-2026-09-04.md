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

## Progress (updated 2026-09-04, implementation complete)

All nine commits landed on `main`, each green at the gate before the next started.

| Task | Commit | Status |
| --- | --- | --- |
| 0 design doc + plan | `500d918` | done |
| 1 JSON value + errors | `c256257` | done |
| 2 type ref, catalog model, validation, fixtures | `61b3a5a` | done |
| 3 SDL printer | `5536774` | done |
| 4 schema search | `f461ffb` | done |
| 5 document builder, selection planner, type check, argv | `120899f` | done |
| 6 lexer, literal renderer, variable inliner | `34c5e69` | done |
| 7 envelope + GatewaySDK protocol | `3b24ae2` | done |
| 8 README tour + final sweep | `34ccf3f` | done |

Final gate: `arch -arm64 /bin/zsh -lc 'swift build && swift test && swiftlint'`
exits 0 — 160 tests in 12 suites pass, swiftlint reports 0 violations in 32 files, the
build emits no warnings. Largest Swift file is 388 lines. `Package.swift` changed only
to add `resources: [.copy("Fixtures")]`; `GatewaySDKKitVersion` and its test are
untouched; the package still has no dependencies and imports only `Foundation`.

### Decisions recorded while implementing

- **The `Threads` golden includes `messages`.** Design §7 prints the root golden as
  `edges { cursor node { id subject } }`, but the brief writes it as
  `node { id subject ... }` with an elision, and this plan's task 5 states that
  "messages at level 3 opens". With the §15 fixture (`Thread.messages: [Message!]!`)
  the depth-3 rule necessarily selects `messages { id snippet direction }`, so the
  committed golden is
  `edges { cursor node { id subject messages { id snippet direction } } }`. The
  design's shorter form was the elided illustration, not a third rule.
- **`threads` gained a `direction: Direction` filter argument** in the gmail fixture so
  that a single custom type is referenced by two matched operations, which is what the
  `includeReferencedTypes` merged-`referenced-by`-label test needs. The SDL golden was
  updated with it.
- **Split-out helpers not named in the plan.** `GatewayVariableBinding` (in
  `GatewayDocumentBuilder.swift`) holds the unknown/required/type-check sequence shared
  by the document and argv builders. `GatewayVariableTypeCheck` exposes a non-throwing
  `matches` alongside the throwing `check` so the tests can assert the §9 matrix
  directly. `GatewayJSONValue.kindName` supplies the `actual` word in
  `variableTypeMismatch`.
- **NSNumber integers go through `int64Value`/`uint64Value`, not `doubleValue`**, so
  `2^53 + 1` survives as an `Int` instead of silently rounding.
- The README's five snippet sections were compiled and run against the real API during
  the final sweep (throwaway test, not committed); each produces the output the README
  documents.

## Review round 1 (2026-09-04): findings addressed

The independent review returned `changes_requested` with four findings (three
execution-confirmed, one plausible). All four are fixed; the reviewer's eight accepted
residual risks needed no code change, including the Threads-golden reconciliation, which
the review confirmed as correct against master design section 2.3.

- **F1 (medium, correctness) — enum in a list rendered quoted.**
  `GraphQLLiteralRenderer.render`'s `.string` case only recognised an enum when the
  unwrapped type was `case .named`, so a single value coerced against `[Direction!]`
  came out as `"INBOUND"` and the emitted document was invalid even though validation
  had passed. Both the `.string` and `.object` cases now resolve the effective named
  type through `namedTypeName(of:)`, which looks through every list and non-null
  wrapper. This also fixes the nested-list case (`[[SendMessageInput!]!]`) that the
  previous single-level `listElementType` unwrap in `.object` missed.
- **F2 (low, undocumented semantics) — omitted nullable variable inlines to `null`.**
  Kept as the behaviour (a token splice cannot delete the surrounding `arg: $var`
  pair), and made explicit: documented on `inline(document:variables:)` and in README
  section 5, and pinned by `unsuppliedNullableInlinesNull`.
- **F3 (low, correctness) — `jsonString()` emitted `inf`/`nan`.** The serializer now
  throws `.invalidJSONValue` for a non-finite double (`write` became `throws`), and
  `GatewayVariableTypeCheck.matches` rejects non-finite doubles as a second line of
  defence. **This fix was incomplete — see F5 in round 2**: the type-check guard only
  inspected the value's root, so a non-finite nested under a `JSON` or custom-scalar
  variable still reached `GatewayArgvBuilder.scalarText` and the inliner's literal
  rendering. Round 2 makes the scan recursive; the accurate statement of the closure is
  recorded there.
- **F4 (low, api-design) — default arguments shadowed conformer overrides.** The
  default argument values moved off the protocol witnesses. `searchSchema(_:options:)`
  and `invoke(_:environment:)` are now exact witnesses, and the one-argument spellings
  are separate overloads that forward through `self`, so they dispatch via the witness
  table. Pinned by `conveniencesDispatchThroughTheWitness`, which asserts both spellings
  reach a conformer's override.

Gate after the fixes: `arch -arm64 /bin/zsh -lc 'swift build && swift test && swiftlint'`
exits 0 — 168 tests in 12 suites (up from 160), 0 lint violations, no build warnings.

## Review round 2 (2026-09-04): F5 addressed

The round-1 F3 fix was incomplete. Round 2 closes it properly and corrects the record.

- **F5 (medium, correctness) — the non-finite guard was not recursive.**
  `GatewayVariableTypeCheck.matches` inspected only the value's root. `JSON` and custom
  scalars accept without descending, so an `inf`/`nan` nested in an object or array
  passed validation and was then rendered bare by the deliberately non-throwing
  `GraphQLLiteralRenderer`. Fixed by scanning the whole value once at the public entry
  point (`containsNonFiniteDouble`) and moving the structural matching into a private
  `matchesType`, which keeps the walk linear instead of re-scanning at every recursion
  level. All four scenarios the review reproduced now throw.
- **Two further holes in the same family, found while fixing F5 and not in the review's
  list.** (a) A non-finite nested under a *custom scalar* — same root cause, fixed by
  the same recursive scan. (b) An overflowing float *default* in the document, e.g.
  `query Q($f: Float = 1e999)`: `Double("1e999")` is `+inf`, and defaults are never
  type-checked (only supplied values are), so validation could not catch it. Fixed in
  `GraphQLVariableInliner.parseConstValue`, which now rejects a non-finite float literal
  as `.malformedDocument`.
- **Argv element path.** Revision instruction 2 offered a choice; fix 1 alone is
  sufficient and no guard was added inside `scalarText`. `GatewayArgvBuilder.build`
  always runs `GatewayVariableBinding.validate` first, so a non-finite can no longer
  reach `scalarText`. Verified concretely: a JSON-typed flag holding
  `.array([.double(.infinity)])` now throws instead of returning
  `["cmd", "go", "--j", "inf"]`. A guard in `scalarText` would have been unreachable
  from any public entry point.
- **Record corrected.** The round-1 F3 entry above no longer claims to have closed the
  argv and inliner paths. The accurate scoping of the remaining renderer risk is: a
  caller who invokes `GraphQLLiteralRenderer.render` *directly* with a value that never
  passed `GatewayVariableTypeCheck` can still obtain `inf`, because the renderer's
  signature is pinned non-throwing by the brief. Every kit-internal path
  (`GraphQLVariableInliner.inline`, `GatewayArgvBuilder.build`,
  `GatewayDocumentBuilder.build`, `GatewaySDK.invoke`) validates first.

Gate after the fixes: `arch -arm64 /bin/zsh -lc 'swift build && swift test && swiftlint'`
exits 0 — 173 tests in 12 suites (up from 168), 0 lint violations, no build warnings.

## Review round 3 (2026-09-04): F6, F7, F8 addressed

- **F6 (medium, correctness) — illegal object keys spliced into GraphQL source.**
  `GraphQLLiteralRenderer` emits an object as `{key: value}` with the key raw, and
  `GatewayVariableTypeCheck` accepts any object under `JSON` or a custom scalar without
  inspecting keys. A key like `a-b`, `with space`, `1st`, or `""` therefore produced a
  document the kit's own lexer rejects. Fixed in `GraphQLVariableInliner.validate`,
  which now walks the effective value of each declaration — supplied value, else parsed
  default, exactly what the splice will render — and throws before any edit is applied.
  Reported as `variableTypeMismatch(name:expected:actual:)` per revision instruction 2:
  the value is not representable for the declared type *at this call site*. Deliberately
  not `malformedDocument`, which the round-2 float-default fix already uses for a
  different meaning (the document text rather than the value), and no new enum case.

  **Why this guard is inliner-local and must not move to the shared chokepoint.** This
  is the opposite call from F5, and the reasoning is recorded in the code comment on
  `firstIllegalObjectKey` so a later reader does not "fix" it by relocating it. A
  non-finite double is unrepresentable on every path, so the shared
  `GatewayVariableTypeCheck` was right for it. An object key like `page-size` is
  perfectly valid on the other two paths: `GatewayDocumentBuilder` passes variables
  through as a GraphQL variables map and never renders a key, and `GatewayArgvBuilder`
  routes objects through `jsonString()` where any key is legal. Moving the guard to the
  shared check would be a real regression for both. Pinned by
  `otherPathsKeepArbitraryKeys`, which asserts a blob with `a-b`, `with space` and `1st`
  still round-trips through the document builder and still argv-encodes unchanged.
- **F7 (low, correctness) — surrogate-pair escapes rejected.** `decodeStringToken` built
  one scalar from four hex digits, so the spec-legal astral spelling `😀` threw
  `invalid unicode escape`. The `\u` branch now reads a hex quad, and on a high surrogate
  consumes the following `\uDC00`–`\uDFFF` escape and combines the pair, throwing only
  when the pair is absent or out of range. A lone high surrogate, a low surrogate on its
  own, and a non-hex quad all still throw.
- **F8 (low, robustness) — a non-array `errors` member was silently dropped.** Shape-A
  parsing admitted the branch on the presence of `data`/`errors` but only populated
  `errors` from an `.array`, so `{"data":null,"errors":"boom"}` reported no errors on a
  failed call. It now degrades the way unparsable output does: one error carrying the
  raw stdout. An explicitly null `errors` is still treated as no errors.

Gate after the fixes: `arch -arm64 /bin/zsh -lc 'swift build && swift test && swiftlint'`
exits 0 — 183 tests in 12 suites (up from 173), 0 lint violations, no build warnings.
Every new test was verified to fail with its fix neutered.

## Review round 4 (2026-09-04): F9, F10 addressed

- **F9 (low, robustness) — the F8 fix left the sibling hole one branch above.**
  `init(parsingCLIOutput:exitCode:)` entered the shape-B branch only on
  `if case .bool(let ok) = root["ok"]`. A payload whose `ok` member was present but not
  a boolean (`"false"`, `null`, `0`, an array) failed that guard, then satisfied the
  shape-A guard because `data` was present, so shape-A parsing ran and never read the
  singular `error` object — reporting a failed call as an empty success, the exact
  outcome F8 was raised to prevent. Fixed with an explicit branch: an `ok` member that
  is not a boolean means the payload is shape B in intent but not in form, so it
  degrades to one `GatewayEnvelopeError(message: stdout)` rather than guessing at
  success or failure. `data` is still surfaced when present.

  **Decision for a shape-A payload carrying a singular `error` member** (the review
  asked for this to be recorded explicitly): **degrade, not consume.** A singular
  `error` belongs to shape B; alongside `data`/`errors` it means the payload matches
  neither documented shape cleanly, so guessing at its structure would be inventing a
  third shape the brief does not describe. Degrading is consistent with the rule F8
  established one round earlier — a member that is present but off-contract yields one
  raw-text error — and with the brief's stated fallback. Nothing is lost: the raw text
  carries the message. Two refinements: a populated `errors` array wins, so the
  singular member never adds a second entry; and an explicitly null `error` is not a
  failure signal.

  **Correction (round 5).** This entry originally ended "After this round no branch of
  the initializer can report a failed call as an empty success". That claim was false
  when written — F11 and F12 disprove it — and it was made from case-by-case reasoning
  rather than from anything the tests pinned. It is withdrawn. The invariant is now
  asserted only to the extent `EnvelopeShapeMatrixTests` actually checks it, and the
  first of the two refinements above was superseded: a payload carrying both a populated
  `errors` array and a singular `error` now degrades rather than preferring the array.
- **F10 (low, documentation) — the object-key rule was invisible to facade authors.**
  F6 added a user-visible inliner rule that lived only in a code comment and the plan.
  It is now in README section 5's rule list, followed by a short paragraph and example
  stating that the rule is inliner-only — the document builder passes variables through
  as a variables map and the argv builder JSON-encodes objects, so both keep accepting
  keys like `page-size` — and the same note is on the `inline(document:variables:)` doc
  comment beside the explicit-null paragraph, citing `otherPathsKeepArbitraryKeys` as
  the pin.

Gate after the fixes: `arch -arm64 /bin/zsh -lc 'swift build && swift test && swiftlint'`
exits 0 — 186 tests in 12 suites (up from 183), 0 lint violations, no build warnings.
Both new envelope tests were verified to fail with the fix neutered.

## Review round 5 (2026-09-04): F11-F14, and the end of the sibling-hole cycle

Rounds 1 through 4 each fixed one branch of `GatewayEnvelope.init(parsingCLIOutput:)`
or its neighbours and each left a structurally identical sibling unfixed, every one
found by the reviewer's adversarial probing rather than by a test. Round 5 stops
patching branches and replaces the parse with an exhaustive classification plus a
matrix test, per the review's instruction 4.

- **F11 (medium, correctness) — the shape-B branch discarded a populated `errors`
  array.** `{"ok":true,"data":{"x":1},"errors":[{"message":"boom"}]}` returned
  `errors == []`: the mirror image of the shape-A-carrying-`error` case fixed in round 4.
- **F12 (low, correctness) — a non-object `error` inside the shape-B branch.** With
  `ok:true` it was dropped entirely; with `ok:false` its text was replaced by the
  `unknown error` placeholder.
- **F13 (low, robustness) — `extensions.requestId` was dropped on the non-boolean-`ok`
  degrade path** but preserved on the sibling shape-A degrade. Fixed by extracting the
  request id (and `data`) up front, before any classification: both are diagnostics
  independent of shape, and a degraded envelope whose message is an opaque blob is
  exactly where a correlation id matters most.
- **F14 (low, documentation) — a false exhaustiveness claim.** The round-4 section
  asserted "After this round no branch of the initializer can report a failed call as an
  empty success". F11 and F12 disprove it; it was written from case-by-case reasoning
  rather than from anything the tests pinned. Withdrawn in place, with a correction note.
  README line 185 re-wrapped to the surrounding paragraph width.

### The structural fix

`init(parsingCLIOutput:exitCode:)` no longer falls through a chain of branches. It
extracts the shape-independent diagnostics, then classifies the payload once:

- **Shape B** iff `ok` is a boolean, no shape-A `errors` is present, and `error` is
  absent or an object.
- **Shape A** iff `ok` is absent, no singular `error` is present, `errors` is absent or
  an array, and at least one of `data`/`errors` is present.
- **Everything else degrades** to one error carrying the raw stdout.

`ok` treats null as present-but-uninterpretable (it is the shape discriminator);
`errors` and `error` treat null as absent (the idiomatic GraphQL spelling for none).
The classification makes the whole hole class unrepresentable rather than fixing its
fifth instance: there is no longer a branch that can read one member and drop another.

### The matrix

`Tests/GatewaySDKKitTests/EnvelopeShapeMatrixTests.swift` walks the full cross product
of `ok` (absent/true/false/non-boolean) x `data` (absent/null/object) x `errors`
(absent/null/empty/populated/non-array) x `error` (absent/null/object/non-object) x
requestId present or not — 480 payloads — asserting the (data, errors.count, message
class, code, requestId, rawOutput, exitCode) tuple for every cell against an oracle
written from the brief's section 7 rather than mirrored from the implementation. Two
further tests state the invariant from both sides: every payload carrying any failure
signal must yield a non-empty `errors`, and every well-formed payload of either
documented shape must yield an empty one.

Confidence check, since the cycle's lesson is that passing tests proved little: each of
the five historical holes was re-introduced one at a time and the matrix caught every
one — F8 20 failing cells, F9 110, F11 158, F12 32, F13 241. The two earliest holes had
previously been findable only by probing.

### Behaviour change recorded

A payload carrying both a populated `errors` array and a singular `error` now degrades
rather than preferring the array. Round 4 preferred the array and left the conflict
unreported, which the round-4 reviewer accepted as a residual risk; under the uniform
classification it is markers from both shapes, so it matches neither. The round-4 test
assertion was updated accordingly — a strengthening (the conflict is now surfaced), not
a weakening.

## Review round 6 (2026-09-04): F15, F16, and the first probe of the catalog surface

Rounds 1-5 all probed the envelope and the inliner. F15 was found by pointing hostile
data at the *catalog* — an input surface no round had touched. That is the lesson of this
round more than either fix.

- **F15 (medium, correctness) — duplicate catalog names crashed the process.**
  Five name-keyed lookups used `Dictionary(uniqueKeysWithValues:)`, which traps on a
  duplicate. A catalog is runtime JSON shipped by five separate gateways, so a duplicate
  argument or input-field name is data the kit must survive, not a programmer error; the
  trap is uncatchable and bypasses the entire throwing-`GatewaySDKError` contract, plus
  `GatewayEnvelope.failure`, which exists so `invoke` never throws. All five sites are now
  `Dictionary(_:uniquingKeysWith:)`.

  **First-wins, and what that does and does not mean.** The duplicate that survives in a
  *lookup* is the first. It does not follow that later duplicates are ignored everywhere:
  `GatewayVariableBinding.validate` iterates `operation.arguments` directly for the
  required-argument and type-check loops, so every duplicate's constraint still applies —
  a value passing the first spelling and failing the second is rejected. That is the
  conservative outcome and is left as is. The two inliner sites are unreachable today
  (`parseVariableDefinitions` rejects a duplicate declaration first) but were hardened
  anyway, with a comment at each of the five sites saying not to restore the trapping
  form.

  **Also added to `validate()`** as defence in depth, since nothing forces a facade to
  call it before `build()`: duplicate argument names within an operation's arguments and
  within a field's arguments, and duplicate field names within an object and within an
  input object, reported at the existing dotted paths. Master design 2.2 says validate()
  reports "duplicate names" without qualification, so this is spec-compatible rather than
  scope creep.
- **F16 (low, correctness) — an empty default selection emitted a bare composite field.**
  `selectionBody` funnelled both "the result is a scalar/enum/JSON leaf, so no selection
  set is correct" and "the result is composite but its default selection came out empty"
  into the same `.none` branch, producing a document GraphQL cannot parse. The two are now
  distinguished: past the leaf guard the result is composite, so an empty selection throws.
  **Branch taken: (b)** — throw `GatewaySDKError.emptySelection(operation:type:)` at build
  time *and* report it from `validate()` at `operation.<name>.result`. The validate() half
  is advisory rather than fatal because `.raw` can still drive such an operation, which the
  new test pins.

  **New error case.** `emptySelection(operation:type:)` is the 15th case. No existing case
  fits: `invalidSelectionPath` is about dot paths, and reusing it would repeat the mistake
  round 3 warned against with `malformedDocument`. Recorded here as a deliberate addition
  to the pinned surface, consistent with the six additions already documented in design 3.
- **Instruction 5 — `{"ok":true,"errors":[]}` keeps degrading.** No code change. The
  residual risk stays explicitly stated, and README section 4 now tells facade authors to
  emit one shape or the other, since they control the producers.

### Surfaces probed this round

Reported plainly because the review asked. Ten catalog-consuming entry points were driven
with one hostile catalog: `validate`, `GatewayVariableTypeCheck.matches/check`,
`GatewayDocumentBuilder.build` (default, `.fields` and `.raw`), `GatewayArgvBuilder.build`,
`GraphQLLiteralRenderer.render`, `GraphQLVariableInliner.inline`, `sdl()`,
`sdlFragment`, `GatewaySchemaSearch.search` (including `includeReferencedTypes`), and
`GatewaySDK.invoke` on both paths. Six trapped before the fix; `sdl()`, `sdlFragment` and
`search` never built a name-keyed dictionary and were already safe. `GatewaySelection.raw`
was probed and reaches the builder's shared validation, so it trapped too and is now
covered.

Still unprobed, and stated as such rather than implied clean: catalogs that are hostile in
ways other than duplicate names (very deep type nesting, self-referential type refs through
lists, enormous field counts), and the SDL printer's block-string output over adversarial
description text.

Verification for F15 is the reverse of the usual neutering check: a trap cannot be caught,
so `HostileCatalogTests` was run against a scratch copy with all five sites reverted and it
**crashed the test process** with seven `Fatal error: Duplicate values for key` traps across
five tests, while the three trap-free tests (sdl, search, validate) still passed. That is
the evidence the fix is load-bearing.

Gate after the fixes: `arch -arm64 /bin/zsh -lc 'swift build && swift test && swiftlint'`
exits 0 — 202 tests in 14 suites (up from 189), 0 lint violations, no build warnings.
