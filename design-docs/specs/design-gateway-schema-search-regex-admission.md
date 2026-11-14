# Design: bounded schema-search regex admission

- Status: accepted; adversarial revision implemented and verified
- Workflow mode: `issue-resolution`
- Workflow execution: `codex-design-and-implement-review-loop-session-106`
- Issue: `local:/Users/taco/gits/tacogips/gateway-sdk-kit-worktrees/runtime#Bound GatewaySDKKit schema-search regex evaluation`
- Intake communications: `comm-001119`, `comm-001120`
- Review decision: `accepted_for_implementation`

## Problem and scope

`GatewaySchemaSearch.search` currently compiles arbitrary caller text as a Swift
`Regex` and evaluates it against every searchable catalog label. Syntactically valid
patterns such as `(.+)+Z` and `.*.*.*.*.*.*.*.*Z` can monopolize the caller's CPU.

This change adds one deterministic admission boundary inside `GatewaySDKKit`. Direct
search callers, the default `GatewaySDK.searchSchema` implementation, and existing CLI
facades receive identical protection without downstream gateway changes.

In scope:

- validate every pattern before regex construction and before any catalog traversal;
- retain a useful, documented regular-expression subset;
- reject policy and compiler failures through `GatewaySDKError.invalidPattern(String)`;
- preserve all search behavior after a pattern is admitted; and
- add deterministic public-path regression coverage and README guidance.

Out of scope:

- replacing Swift Regex, adding a dependency, or relying on a wall-clock timeout;
- changing catalog construction, tiers, credentials, transport, or gateway behavior;
- adding caller-configurable policy limits;
- changing public search models, options, defaults, or error cases; and
- changing downstream gateway repositories or adding a Cursor-specific adapter.

## Admission boundary and data flow

The synchronous search path has a fixed order:

1. Receive `pattern` and `options`.
2. Validate `pattern` with the central internal admission policy. This is the first
   executable action in `search`; it does not read the catalog.
3. On policy rejection, throw `GatewaySDKError.invalidPattern(String)` immediately.
4. Construct `Regex(pattern)` only after admission succeeds. Map any compiler failure
   to the same public error case.
5. Only then traverse catalog operations and types, collect matches, sort, expand
   referenced types when requested, and apply the final limit exactly as today.

No path may compile first and validate later. No rejection path may inspect catalog
operations, types, labels, summaries, descriptions, SDL, or tier metadata. Review must
independently confirm that both `Regex(pattern)` and every matching loop occur after the
admission call.

The policy is an internal, stateless `GatewaySDKKit` owner in
`Sources/GatewaySDKKit/GatewaySchemaSearchPattern.swift`. It scans the original string
without evaluating it or allocating an unbounded character array. Admission takes O(n)
time and O(1) scanner state after the byte bound succeeds.

## Supported subset and fixed limit

Patterns are limited to 256 UTF-8 bytes. Exactly 256 bytes is eligible for admission;
byte 257 is rejected. The byte rule prevents multi-byte text from bypassing the bound.

The supported subset includes:

- literals, Unicode text, and the empty pattern;
- anchors, dot, and top-level alternation only;
- character classes;
- unquantified capturing groups, including nested groups that contain no alternation;
- ordinary non-backreference escapes and escaped metacharacters; and
- at most one unescaped optional quantifier (`?`) in the entire pattern.

Representative admitted patterns are `thread`, `^sendMessage$`, `[Dd]irection`,
`^threads$|^sendMessage$`, and `threads?`. Unsupported metacharacters may be
searched as escaped literals or as character-class members when Swift Regex accepts
that spelling. A literal closing bracket must be escaped when ambiguity would otherwise
make it an unmatched structure.

An unescaped `|` is admitted only at group depth zero. Top-level alternatives form a
bounded, additive list of complete branches; they cannot become independent choices
concatenated inside repeated groups. An escaped `\|` or a `|` inside a character class
remains literal. Grouped alternation is rejected even without a quantifier because
concatenating ambiguous groups can itself multiply the engine's search paths.

The empty pattern remains admitted to avoid an unrelated compatibility change. It can
match broadly, but it has no repetition operator and traverses only the trusted catalog.

This is deliberately a conservative subset, not a claim that every excluded Swift
Regex feature is intrinsically unsafe. The policy is fixed so direct SDK and CLI
consumers cannot weaken the shared boundary.

## Validation rules

The byte check runs before structural scanning. The scanner then tracks only string
position, escape state, character-class state, group depth, whether the previous token
was a quantifier or a closed group, and whether the one optional-quantifier allowance is spent.
ASCII metacharacters act as operators only when unescaped and outside a character
class. Encountering `|` while group depth is positive rejects the pattern immediately.

| Category | Rejection rule | Representative inputs |
| --- | --- | --- |
| Oversized | More than 256 UTF-8 bytes | 257 ASCII bytes; Unicode crossing byte 256 |
| Numeric backreference | An escape followed by an ASCII digit | `(a)\1` |
| Named backreference | An escape followed by `k` or `g`, regardless of delimiter spelling | `(a)\k<a>`, `(a)\g<a>` |
| Extension group | Any group beginning `(?`; this includes lookaround, inline options, non-capturing groups, and named captures | `(?=a)`, `(?!a)`, `(?<=a)`, `(?i)a`, `(?:a)`, `(?<n>a)` |
| Grouped alternation | An unescaped `|` at positive group depth; only depth-zero alternation is admitted | `(a|aa)`, `(a|b)(c|d)` |
| Counted quantifier | Unescaped `{` or `}` outside a character class | `a{2}`, `a{1,3}` |
| Unbounded quantifier | Any unescaped `*` or `+` outside a class | `a+Z`, `.*Z`, `(.+)+Z` |
| Group quantification | `?` immediately after a closed group | `(ab)?` |
| Repeated optional quantifier | More than one unescaped `?` outside classes in the complete pattern | `a??` |
| Unmatched structure | A closing `)` at zero group depth or a `]` outside a class | `abc)`, `abc]` |
| Incomplete structure | Trailing escape, unclosed class, or positive group depth at end of input | `foo\`, `[abc`, `(abc` |
| Compiler-detected malformed syntax | Structural admission succeeds but Swift Regex rejects the spelling | `[z-a]` |

The representative-input column shows the exact regex text passed to `search`, not a
Swift source literal. Escaping is therefore recorded separately:

| Case | Regex text | Swift source literal |
| --- | --- | --- |
| Rejected numeric backreference | `(a)\1` | `"(a)\\1"` |
| Rejected named backreference | `(a)\k<a>` | `"(a)\\k<a>"` |
| Rejected trailing escape | `foo\` | `"foo\\"` |
| Admitted escaped-backslash control | `\\1` | `"\\\\1"` |

The reproduced zero-quantifier bypass,
`String(repeating: "(a|aa)", count: 24) + "Z"`, is 145 UTF-8 bytes and is rejected at
the first group-contained `|`. The policy does not compile it and does not inspect or
match any catalog label.

An escape consumes exactly its following character. Therefore an escaped quantifier
does not spend the optional-quantifier allowance, an escaped backslash followed by a digit is not
a backreference, and an escaped closing bracket inside a character class does not close
the class. Quantifier-looking characters, braces, and parentheses inside a character
class are class content. Parentheses outside classes change group depth, and a closing
parenthesis may reduce only a positive depth.

Rejecting every `(?` group and every `\k` or `\g` escape is intentional and fail
closed. It avoids depending on the host toolchain's evolving collection of extension
and named-backreference spellings. Remaining malformed syntax is delegated to the
Swift Regex compiler only after the structural policy admits it.

## Error contract

Every policy failure throws `GatewaySDKError.invalidPattern(String)` with a bounded,
deterministic policy reason. Regex compiler failures continue to be wrapped in the same
case. The public enum, signatures, Codable models, and description prefix
`invalid search pattern:` do not change.

Callers that already catch `GatewaySDKError.invalidPattern` remain source- and
behavior-compatible. Newly rejected, syntactically valid patterns are the intended
security restriction. Rejection diagnostics must not echo catalog data or credentials.

## Preserved search behavior

For every admitted pattern, the existing search pipeline remains unchanged:

- contains matching still covers definition names, operation and field arguments,
  fields, enum values, summaries, and descriptions;
- exact whole-name matches still sort before substring matches;
- exact, kind, and name ordering remain stable;
- `kinds` still restricts direct catalog traversal;
- `includeReferencedTypes` retains its current transitive input and one-level result
  expansion and continues to bypass `kinds` as documented;
- duplicate handling, `matchedOn` labels, SDL fragments, tier metadata, catalog order,
  and GatewaySDK defaults remain unchanged; and
- `limit` still truncates only the final ordered result list.

No credentials, environment, network, or transport path is introduced or changed.

## Verification design

`Tests/GatewaySDKKitTests/SchemaSearchTests.swift` will exercise admission through the
public `GatewaySchemaSearch.search` path with table-driven inputs. Every rejected input
asserts the exact `GatewaySDKError.invalidPattern` case. Coverage includes:

- grouped/nested, repeated optional, unbounded, and both reproduced CPU-bound patterns;
- 256-byte acceptance and 257-byte rejection, with ASCII and multi-byte boundaries;
- numeric and named backreferences, including delimiter variants and escaped-backslash
  non-backreference controls;
- positive and negative lookaround, inline options, non-capturing groups, named groups,
  and other `(?` extension groups;
- grouped alternation, including the exact 145-byte zero-quantifier bypass formed by
  repeating `(a|aa)` 24 times and appending `Z`;
- counted quantifiers;
- depth-zero alternation, escaped `\|`, and class-contained `|` as accepted controls;
- unmatched closers, trailing escapes, and unclosed classes/groups as policy rejections;
- `a+Z` and `.*Z` against a long repetitive public catalog label, rejected before matching;
- `[z-a]` as a structurally admitted pattern that Swift Regex rejects, proving the compiler
  fallback remains mapped to `GatewaySDKError.invalidPattern`; and
- admitted literals, Unicode, empty input, anchors, dot, depth-zero alternation, classes,
  unquantified groups, ordinary escapes, and exactly one optional quantifier.

Existing schema-search tests remain the regression contract for ordering, kinds,
referenced-type expansion, limits, tier metadata, labels, SDL, Codable, and no-match
behavior. `Tests/GatewaySDKKitTests/GatewaySDKProtocolTests.swift` must pass the
policy-rejected `(.+)+Z` pattern through the default `GatewaySDK.searchSchema`
implementation and assert `GatewaySDKError.invalidPattern`, proving default delegation
reaches central admission. Compiler-fallback coverage must separately use `[z-a]`; unlike
the unclosed `[` pattern, `[z-a]` passes structural admission and is then rejected by Swift
Regex. Tests use small fixtures and no timing assertions: dangerous
patterns must be rejected before matching, so coverage is fast and deterministic.

The zero-quantifier bypass regression must call public `GatewaySchemaSearch.search`
with a catalog containing a 48-`a` searchable label and assert
`GatewaySDKError.invalidPattern`. It must use the exact 145-byte reproduced pattern and
must not use a wall-clock threshold. The test proves the public path rejects the pattern;
source review separately confirms the admission call lexically precedes `Regex(pattern)`
and both catalog loops. Existing safe grouped-alternation tests must use equivalent
depth-zero alternatives, such as `^threads$|^sendMessage$`.

Required verification commands:

```bash
mise exec -- swift test --filter SchemaSearchTests
mise run build
mise run test
mise run lint
rg --files -g '*.swift' | xargs wc -l
git diff --check
git status --short --branch
```

Every non-generated Swift file must remain below 1000 lines. Adversarial review must
find no unresolved high- or medium-severity issue before acceptance.

## Documentation and rollout

`README.md` will document the 256-byte limit, admitted subset, depth-zero-only
alternation, grouped-alternation exclusion, literal `|` escaping, other excluded
constructs, and `GatewaySDKError.invalidPattern` behavior beside the schema-search
example. This issue-specific document is the controlling delta to the existing package
and runtime designs.

Rollout is a source-compatible package update on `feat/graphql-runtime`. It adds no
dependency, migration, gateway-specific switch, credential behavior, network behavior,
or transport behavior. No downstream gateway change is allowed or required. The
implementation, tests, README, and accepted design must be committed together without
pushing; final handoff requires a fully committed, clean worktree.

## Reference behavior and intentional divergences

Behavioral evidence came from:

- `AGENTS.md`;
- `.codex/skills/swift-coding-agent/SKILL.md`;
- `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`; and
- `/Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk/Sources/WrikeGatewayCore/SDK/GatewaySchemaSearchPattern.swift`.

The Wrike implementation provides evidence for a 256-byte ceiling, a single bounded
scan, fail-closed structure, and core denial categories. GatewaySDKKit does not copy
gateway-specific code.

Intentional divergences from the Wrike reference are:

- policy ownership is central in `GatewaySDKKit`, not a Wrike adapter;
- failures use `GatewaySDKError.invalidPattern(String)`, not
  `GatewayError.validation`;
- named backreference prefixes are rejected in addition to numeric backreferences;
- the scan does not first allocate `Array(pattern)`;
- unmatched closing groups and brackets are explicitly rejected;
- alternation is admitted only at group depth zero; the Wrike reference admits grouped
  alternation and therefore does not block the reproduced zero-quantifier bypass; and
- README guidance and public-path integration tests define one portable subset for all
  gateways.

There is no Cursor CLI behavior to adapt. This workflow is Codex-only and the policy
sits below every CLI facade. The mapping is identity: every direct SDK and CLI consumer
reaches the same admitted `GatewaySchemaSearch` path.

## Design provenance reconciliation

The pre-existing untracked
`design-docs/gateway-schema-search-regex-admission-design-2026-09-05.md` was a proposed
Step 2 artifact for workflow session 98. It named the same local issue, risk examples,
central boundary, 256-byte policy, stable error case, verification gates, and rollout
constraints as the authoritative session-106 intake. It contained no accepted review
decision or unrelated user content.

Session 106 therefore adopts its substantive design after revalidating it against the
current source and Codex references, updates the communication and workflow provenance,
adds explicit named-backreference, unmatched-bracket, no-character-array, and default
delegation requirements, and relocates it to this repository-rule-compliant `specs`
path. The stale untracked path is removed as part of that reconciliation; its design
content is preserved here.

## Risks and mitigations

- **High — ambiguous alternation multiplies paths without quantifiers.** Reject every
  group-contained alternation, retain only additive depth-zero branches, and exercise
  the exact 145-byte reproduced bypass through the public search path.
- **High — an admitted unbounded quantifier monopolizes CPU.** Reject every unescaped
  `*` and `+` before Regex construction, allow at most one bounded `?`, and exercise
  `a+Z` and `.*Z` through public search against a long repetitive label.
- **Medium — escape, class, or group state permits a bypass.** Use explicit scanner
  states, reject negative or unfinished structures, and table-test boundary spellings
  both inside and outside classes.
- **Medium — a useful grouped-alternation pattern becomes unsupported.** Document
  depth-zero alternatives and literal-pipe escaping, retain anchors, classes,
  non-alternating groups, and one quantifier, and regression-test accepted equivalents.
- **Medium — shared schema-search behavior drifts.** Isolate admission from result
  collection and retain existing schema-search and GatewaySDK delegation coverage.
- **Low — compiler diagnostics vary by Swift toolchain.** Assert the stable error case
  and prefix; require exact messages only for policy-owned rejections.

## Issue-to-design traceability

| Intake acceptance signal | Design section |
| --- | --- |
| Central admission before regex construction and traversal | Admission boundary and data flow |
| Stable `invalidPattern` failure surface | Error contract |
| Deterministic denial categories | Validation rules |
| Reject the reproduced zero-quantifier alternation bypass before traversal | Supported subset; Validation rules; Verification design |
| Useful supported subset and accepted-pattern regressions | Supported subset; Verification design |
| Preserve tiers, traversal, labels, ordering, filters, expansion, SDL, limits, defaults, credentials, and transport | Preserved search behavior |
| Document subset, byte limit, exclusions, escaping, and error behavior | Documentation and rollout |
| No unresolved high/medium review finding; independently inspect call order | Admission boundary; Verification design |
| Run focused/full build, test, lint, line-count, and Git checks | Verification design |
| Commit cleanly on `feat/graphql-runtime` without push | Documentation and rollout |

## Decisions and open questions

Decisions are complete for implementation planning: central ownership, fixed byte
limit, depth-zero-only alternation, conservative subset, scanner states, admission
order, stable public error, preservation boundary, tests, documentation, review gate,
and rollout are specified.

Open user questions: none. No file under `design-docs/user-qa/` is required.

This Step 2 rerun retains the `comm-001123` and `comm-001126` corrections and addresses
the Step 3 high-severity finding from `comm-001129`: alternation is now limited to group
depth zero, the exact zero-quantifier bypass is a required public-path rejection, and
the supported subset, validation, verification, README plan, risks, and Wrike divergence
all carry the stronger boundary. Step 5 feedback was empty and the ordinary implementation
self-review accepted the initial boundary. Step 7 adversarial review `comm-001142` then
rejected it after finding that admitted `*` and `+` can still cause superlinear Swift
Regex matching; this revision rejects them before Regex construction and retains only one
bounded optional quantifier.
