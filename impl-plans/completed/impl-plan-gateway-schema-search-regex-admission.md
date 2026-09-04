# Implementation plan: bounded schema-search regex admission

- Status: complete; archived after adversarial-review correction was committed and verified
- Workflow mode: `issue-resolution`
- Workflow execution: `codex-design-and-implement-review-loop-session-106`
- Issue: `local:/Users/taco/gits/tacogips/gateway-sdk-kit-worktrees/runtime#Bound GatewaySDKKit schema-search regex evaluation`
- Branch: `feat/graphql-runtime`
- Accepted design: `design-docs/specs/design-gateway-schema-search-regex-admission.md`
- Design-review communication: `comm-001132`
- Design-review decision: `accepted_for_implementation_planning`
- Scope: one dependency-free, gateway-neutral schema-search denial-of-service hardening feature

## Controlling contract and traceability

Read these references before implementation, in order:

1. `design-docs/specs/design-gateway-schema-search-regex-admission.md` is the
   accepted source of truth. Do not reopen its grammar, limits, public error surface,
   test matrix, or rollout decisions during implementation.
2. `AGENTS.md` supplies repository constraints: Swift 6, Foundation only, no package
   dependency, no gateway-specific or credential behavior, SwiftLint, and every Swift
   file below 1000 lines.
3. `.codex/skills/swift-coding-agent/SKILL.md` supplies the Swift implementation and
   verification workflow.
4. `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`
   supplies the neutral package boundary and existing schema-search behavior.
5. `/Users/taco/gits/tacogips/wrike-gateway-worktrees/gateway-sdk/Sources/WrikeGatewayCore/SDK/GatewaySchemaSearchPattern.swift`
   is read-only behavioral evidence for a bounded scan and core denial categories.

The Wrike reference is not copied and no downstream repository is modified. Preserve
the accepted divergences: central `GatewaySDKKit` ownership;
`GatewaySDKError.invalidPattern(String)` rather than gateway validation errors; numeric
and named-backreference rejection; no `Array(pattern)` allocation; explicit unmatched
closer rejection; alternation only at group depth zero; and one documented portable
subset shared by direct SDK, default `GatewaySDK`, and CLI consumers.

## Execution rules

- Preserve the untracked accepted design document and all unrelated worktree state.
- Limit writes to the files listed by the tasks below. `Package.swift`, downstream
  gateway repositories, credentials, transport, catalog models, tiers, and public API
  signatures are outside the write scope.
- Keep admission deterministic: no clocks, subprocesses, concurrency, or matching as
  part of validation. Check the 256 UTF-8-byte limit before structural scanning; scan
  the original string in O(n) time with O(1) state and without an unbounded character
  array.
- Policy rejection, compiler rejection, and malformed accepted spellings must all use
  the existing `GatewaySDKError.invalidPattern(String)` case. Policy-owned diagnostics
  are bounded and deterministic and must not include catalog data.
- Do not commit until implementation review has no unresolved high- or mid-severity
  finding and every required verification command passes. Commit is authorized; push
  is not authorized.

## Task breakdown

### T1 — Implement and integrate the central admission boundary

Write scope:

- New: `Sources/GatewaySDKKit/GatewaySchemaSearchPattern.swift`
- Modify: `Sources/GatewaySDKKit/GatewaySchemaSearch.swift`

Deliverables:

- Add one internal, stateless policy owner with a fixed 256 UTF-8-byte ceiling and a
  single structural scan over the original string.
- Track escape state, character-class state, group depth, prior quantifier/closed-group
  state, and the one permitted unescaped `?` allowance.
- Reject more than 256 bytes; numeric and `k`/`g` named backreferences; every `(?`
  extension group; group-contained alternation; unescaped braces; quantified groups;
  every unescaped `*` or `+`, repeated `?`; unmatched closers; trailing escapes;
  and unclosed classes or groups. Treat escaped operators and class contents according
  to the accepted design.
- Make policy admission the first executable action in `GatewaySchemaSearch.search`,
  before `Regex(pattern)`, every catalog read, and every matching loop. Preserve the
  existing compiler-error mapping after admission.
- Leave the admitted-pattern result pipeline byte-for-byte behaviorally equivalent:
  labels, exact-match ordering, kinds, referenced-type expansion, duplicate handling,
  SDL, tiers, defaults, and final limit stay unchanged.

Dependencies: accepted design and repository references only.

Task verification:

```bash
mise exec -- swift build
sed -n '50,115p' Sources/GatewaySDKKit/GatewaySchemaSearch.swift
rg -n 'Array\(pattern\)|Regex\(pattern\)|for operation in catalog\.operations|for type in catalog\.types' Sources/GatewaySDKKit
```

### T2 — Pin policy, compiler-fallback, and default-delegation behavior

Write scope:

- Modify: `Tests/GatewaySDKKitTests/SchemaSearchTests.swift`
- Modify: `Tests/GatewaySDKKitTests/GatewaySDKProtocolTests.swift`

Deliverables:

- Add table-driven public-path policy-rejection coverage for nested/grouped,
  adjacent, separated, counted, backreference, extension-group, lookaround,
  inline-option, malformed-structure, and oversized patterns. Assert the exact
  `GatewaySDKError.invalidPattern` case; assert exact diagnostics only when the policy
  owns them.
- Cover exactly 256 accepted and 257 rejected UTF-8 bytes with ASCII and multi-byte
  boundaries; include numeric/named-backreference variants and escaped-backslash
  controls.
- Exercise both reproduced CPU-bound inputs. Build the 145-byte
  `String(repeating: "(a|aa)", count: 24) + "Z"` input exactly, search a catalog with a
  48-`a` label, and assert rejection without a wall-clock threshold.
- Prove admitted literals, Unicode, empty input, anchors, dot, classes,
  non-alternating groups, ordinary escapes, depth-zero alternation, escaped/class
  pipes, and exactly one optional quantifier remain useful; reject `a+Z` and `.*Z`
  before matching a long repetitive public catalog label.
- Use `[z-a]` as the structurally admitted but compiler-rejected fallback case.
- Add `GatewaySDKProtocolTests` coverage that sends `(.+)+Z` through the default
  `GatewaySDK.searchSchema` implementation and receives the stable error case.
- Retain all existing schema-search regression tests unchanged in meaning.

Dependencies: T1 for compilation and execution; test authoring may proceed in parallel
because the write scopes are disjoint.

Task verification:

```bash
mise exec -- swift test --filter SchemaSearchTests
mise exec -- swift test --filter GatewaySDKProtocolTests
```

### T3 — Document the supported public subset

Write scope:

- Modify: `README.md`

Deliverables:

- Beside the schema-search example, document the 256 UTF-8-byte limit, exactly-one
  optional-quantifier allowance, exclusion of unbounded `*` and `+`, depth-zero-only alternation, escaped literal pipe,
  class behavior, supported simple constructs, excluded backreferences/extensions/
  counted or repeated quantifiers/grouped alternation, and the stable
  `GatewaySDKError.invalidPattern` result.
- Describe the policy as a deliberately conservative supported subset, not a full
  safety classification of Swift Regex.
- Make no claim of timeouts, configurable limits, gateway-specific behavior, or
  transport protection.

Dependencies: accepted design only. This task is write-disjoint from T1 and T2 and may
be authored in parallel.

Task verification:

```bash
rg -n '256|UTF-8|alternation|backreference|invalidPattern|quantifier' README.md
```

### T4 — Integrate, independently review, verify, and prepare the authorized commit

Write scope: no new production scope; fixes are confined to T1-T3 files and the
accepted design/plan documents when review evidence requires a documentation-only
correction.

Deliverables:

- Review the source order independently: admission precedes regex construction and
  both catalog loops, while rejection performs no catalog inspection or match.
- Review scanner state transitions against every accepted and rejected boundary,
  including escapes inside and outside classes and the zero-quantifier grouped-
  alternation bypass.
- Confirm the diff contains no package dependency, public signature, gateway-specific,
  credential, network, transport, tier, catalog, or downstream repository change.
- Resolve every high- and mid-severity implementation-review finding before acceptance;
  record accepted low findings and verification gaps in the progress log and handoff.
- Run the full verification matrix, stage only the exact reviewed file allowlist,
  commit once on `feat/graphql-runtime`, do not push, and prove the worktree is clean.

Dependencies: T1, T2, and T3 complete.

## Parallelization

The only approved parallel authoring group is T1, T2, and T3 because their write scopes
are disjoint (`Sources/`, `Tests/`, and `README.md`). T2 execution depends on T1, and T4
depends on all three. Any review fix touching another task's file must be serialized
after its authoring is complete. No task may write outside this repository.

## Required verification

Run from `/Users/taco/gits/tacogips/gateway-sdk-kit-worktrees/runtime` in this order:

```bash
mise exec -- swift test --filter SchemaSearchTests
mise exec -- swift test --filter GatewaySDKProtocolTests
mise run build
mise run test
mise run lint
rg --files -g '*.swift' | xargs wc -l
sed -n '50,115p' Sources/GatewaySDKKit/GatewaySchemaSearch.swift
rg -n 'Array\(pattern\)|Regex\(pattern\)|for operation in catalog\.operations|for type in catalog\.types' Sources/GatewaySDKKit
git diff --check
git diff --cached --check
git status --short --branch
```

Before commit, the line-count output must show every non-generated Swift file below
1000 lines. After the authorized commit, rerun:

```bash
git diff --check
git diff --cached --check
git status --short --branch
```

The final status must show `feat/graphql-runtime` with no staged, unstaged, or untracked
files. Record command, status, and concise result; never report a deferred command as
passed.

## Completion criteria

- [x] The policy rejects every accepted-design denial category before regex construction
  or catalog traversal and admits the documented subset within the byte bound.
- [x] Direct `GatewaySchemaSearch`, default `GatewaySDK.searchSchema`, and existing CLI
  consumers share the same central boundary without downstream changes.
- [x] All policy and compiler failures retain `GatewaySDKError.invalidPattern(String)` and
  the `invalid search pattern:` description prefix.
- [x] Existing search semantics and public types remain compatible for admitted patterns.
- [x] Deterministic tests cover the exact reproduced inputs, boundary bytes, escape/class/
  group states, accepted controls, compiler fallback, and default delegation without
  timing assertions.
- [x] README guidance matches the accepted design and implementation.
- [x] No dependency, gateway-specific, credential, network, transport, package-manifest,
  tier, or catalog change appears in the diff.
- [x] Focused tests, full build/tests, SwiftLint, line count, source-order review, and Git
  checks pass; independent review has no unresolved high or mid finding.
- [x] The accepted design, implementation plan, source, tests, and README are committed
  together on `feat/graphql-runtime`; the repository is clean and no push occurred.

## Progress log expectations

The implementation step must append dated entries below after each task and review
cycle. Each entry records task ID, state (`planned`, `in_progress`, `blocked`, or
`complete`), exact changed paths, dependency state, verification commands with actual
results, findings/decisions, intentional deviations approved by the accepted design,
and the next action. Never erase earlier evidence or mark a task complete while a
required command is deferred or failing.

Initial entry:

- 2026-09-05 — T1-T4 `planned`; design accepted by `comm-001132` with decision
  `accepted_for_implementation_planning`; Step 3 feedback and findings are empty; no
  Step 5 rerun feedback exists.

- 2026-09-05 — T1 `complete`; added
  `Sources/GatewaySDKKit/GatewaySchemaSearchPattern.swift` and integrated its first-action
  `validate` call in `Sources/GatewaySDKKit/GatewaySchemaSearch.swift`. The dependency-free
  scan enforces the 256 UTF-8-byte bound and all accepted structural rejections before
  `Regex(pattern)` and both catalog loops. Source-order inspection and
  `rg -n 'Array\\(pattern\\)|Regex\\(pattern\\)|for operation in catalog\\.operations|for type in catalog\\.types' Sources/GatewaySDKKit`
  passed; no `Array(pattern)` allocation is present.

- 2026-09-05 — T2 `complete`; updated
  `Tests/GatewaySDKKitTests/SchemaSearchTests.swift` and
  `Tests/GatewaySDKKitTests/GatewaySDKProtocolTests.swift`. Public-path tables cover both
  reproduced CPU-bound patterns, the exact 145-byte zero-quantifier bypass against a
  48-`a` catalog label, nested/grouped and repeated quantifiers, byte boundaries,
  backreference variants, extension groups, malformed structure, classes/escapes, safe
  controls, compiler fallback, and default `GatewaySDK` delegation. Existing grouped
  alternation test spellings were converted to equivalent depth-zero alternatives, as
  required by the accepted policy, without changing their search assertions.
  `arch -arm64 mise exec -- swift test --filter SchemaSearchTests` and
  `arch -arm64 mise exec -- swift test --filter GatewaySDKProtocolTests` passed.

- 2026-09-05 — T3 `complete`; updated `README.md` beside the schema-search example with
  the fixed limit, admitted subset, depth-zero alternatives, literal-pipe spelling,
  excluded constructs, and stable error case. No gateway, package dependency, transport,
  credential, tier, catalog, or public-signature change was made.

- 2026-09-05 — T4 `complete` pending authorized commit; independent review found no high
  or medium finding. `arch -arm64 mise run build`, `arch -arm64 mise run test` (224 tests),
  and `arch -arm64 mise run lint` (0 violations) passed. `rg --files -g '*.swift' | xargs
  wc -l` confirmed every Swift file is below 1000 lines. `git diff --check` and
  `git diff --cached --check` passed. The `arch -arm64` prefix is required because this
  host shell runs under Rosetta while the installed toolchain and test runner are arm64.
  Step 5 feedback is empty; the subsequent Step 7 adversarial review is recorded below;
  next action is stage the reviewed allowlist,
  commit once on `feat/graphql-runtime`, then rerun Git checks without pushing.

- 2026-09-05 — T4 `complete`; committed the exact reviewed allowlist
  (`Harden schema search regex admission`) on `feat/graphql-runtime`, without pushing.
  Post-commit `git diff --check`, `git diff --cached --check`, and
  `git status --short --branch` passed with no staged, unstaged, or untracked files.

- 2026-09-05 — T2/T4 `in_progress`; Step 6 self-review `comm-001137` found that the
  multi-byte oversized case used 258 rather than the required exact 257 UTF-8 bytes.
  Replace it with an asserted 257-byte multi-byte pattern, rerun focused and full gates,
  then amend the authorized commit without pushing.

- 2026-09-05 — T2/T4 `complete` pending authorized commit amendment; replaced the 258-byte
  multi-byte case with `String(repeating: "é", count: 128) + "a"` and asserted its
  `utf8.count == 257` before public-path rejection. `arch -arm64 mise exec -- swift test
  --filter SchemaSearchTests`, `arch -arm64 mise exec -- swift test --filter
  GatewaySDKProtocolTests`, `arch -arm64 mise run build`, `arch -arm64 mise run test`
  (224 tests), `arch -arm64 mise run lint` (0 violations), line-count, and pre-amend Git
  checks passed. The `comm-001137` mid-severity finding is resolved; next action is amend
  the authorized commit and rerun clean-worktree checks without pushing.

- 2026-09-05 — T4 `complete`; amended the authorized `Harden schema search regex admission`
  commit on `feat/graphql-runtime` without pushing. Post-amend `git diff --check`,
  `git diff --cached --check`, and `git status --short --branch` passed with a clean
  worktree.

- 2026-09-05 — T1-T4 `in_progress`; Step 7 adversarial review `comm-001142` rejected the
  prior commit after the ordinary implementation self-review accepted it and adversarial
  reproduction showed superlinear public-path CPU use from admitted `a+Z` and `.*Z` on a
  repetitive label. The approved fail-closed correction rejects every
  unescaped `*` and `+`, retains at most one bounded `?`, adds long-label public-path
  rejection tests, refreshes design/README/plan evidence, then reruns all gates and
  amends the authorized commit without pushing.

- 2026-09-05 — T1-T4 `complete` pending authorized commit amendment; rejected unescaped
  `*` and `+` before Regex construction, retained at most one bounded `?`, and added
  public `GatewaySchemaSearch` regressions for `a+Z` and `.*Z` against a 12,000-byte
  repetitive summary without a timing threshold. Replaced the compiler fallback with
  structurally admitted `[z-a]`, refreshed accepted design and README behavior, and
  recorded both the ordinary and adversarial review decisions. `arch -arm64 mise exec --
  swift test --filter SchemaSearchTests`, `arch -arm64 mise exec -- swift test --filter
  GatewaySDKProtocolTests`, `arch -arm64 mise run build`, `arch -arm64 mise run test`
  (224 tests), `arch -arm64 mise run lint` (0 violations), line-count, source-order,
  documentation search, and pre-amend Git checks passed. `comm-001142` high finding and
  residual provenance finding are resolved; next action is amend the authorized commit
  and rerun clean-worktree checks without pushing.

- 2026-09-05 — T4 `complete`; amended the authorized `Harden schema search regex admission`
  commit with the `comm-001142` high-severity correction and documentation refresh,
  without pushing. Post-amend `git diff --check`, `git diff --cached --check`, and
  `git status --short --branch` passed with a clean worktree.

## Risks and controls

- High: group-contained ambiguity bypasses quantifier controls. Control: reject every
  positive-depth `|` and test the exact 145-byte public-path reproduction.
- High: admitted syntax still causes unbounded matching work. Control: reject every
  unescaped `*` and `+`, retain only one bounded `?`, and test `a+Z` and `.*Z` against a
  long repetitive public catalog label without a timing assertion.
- Medium: escape, class, group, or boundary state admits a bypass. Control: explicit
  scanner state plus table-driven inside/outside and 256/257-byte tests.
- Medium: useful search patterns regress. Control: accepted-control matrix and all
  existing search tests, including depth-zero alternation equivalents.
- Medium: central search behavior drifts during integration. Control: isolate the new
  boundary before the existing pipeline and run focused plus full suites.
- Low: Swift compiler diagnostics vary. Control: exact policy diagnostics only;
  compiler failures assert the stable public error case and description prefix.
- Low: concurrent authoring causes overlap. Control: parallelize only disjoint write
  scopes and serialize integration/review fixes in T4.
