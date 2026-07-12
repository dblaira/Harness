# Deep Research: A verified-build and independent-review system for Harness

Date: 2026-07-12
Repository audited: `dblaira/Harness`
Decision question: How do we stop handing Adam builds that pass minor testing but fail immediately in real use?

## Executive summary

Harness does not currently have a release gate. It has a large unit/integration test suite, a secret-scanning pre-commit hook, two ad hoc screenshots, and one live “satisfaction gate” test. None of these mechanically prevents an agent from pushing a change to `main` and handing it to Adam without independent review or visible feature verification.

The live GitHub state is decisive:

- Repository is public.
- `main` is not protected.
- GitHub Actions has zero workflows.
- There are zero open pull requests.
- The local agent rule explicitly says to commit and push directly to `main`.

The satisfaction gate is also fail-open. If Ollama or Fuseki is unavailable, the test returns normally and is reported as passing. If it runs, its quality bar is only: nonempty answer, internal success flag, and no `Harness stopped` prefix. It does not launch Harness, exercise the UI, observe the visible result, or compare the outcome with Adam’s sentence. Static inspection found 355 test functions and zero `XCUIApplication`/UI-automation references.

The required correction is not “test a little more.” It is a two-gate delivery system:

1. **Merge gate:** exact diff, deterministic checks, independent GPT-5.6 Sol review, security/static analysis, and protected `main`.
2. **Handoff gate:** signed app launched on Adam’s Mac, critical user flow executed from the visible UI, screenshots/video and machine-readable results bound to the exact commit, then a release certificate. An agent cannot end its task with “done” unless this evidence exists.

GPT-5.6 Sol should be a reviewer, not the release oracle. Current research shows frontier models can miss most human-flagged review issues, and model judgment becomes materially safer when findings are tested against executable behavior. The final authority must therefore be layered evidence: code review + automated execution + visible product proof.

## Implementation installed from this research

Branch `codex/verified-build-gates` installs the recommended system as repository code:

- agent-owned pull requests and a literal acceptance-contract validator;
- protected-base acceptance validation that proposed PR code cannot weaken;
- GitHub-hosted macOS tests, SwiftLint, changed-code Periphery, and Swift/Python CodeQL;
- an immutable-SHA, read-only `gpt-5.6-sol` review with structured fail-closed output;
- a signed macOS XCUITest target and a handoff command that records the exact named requirement test;
- a fail-closed live Ollama + Fuseki satisfaction proof, excluded by name from deterministic hosted tests and required by the signed local handoff;
- commit-keyed initial/final screenshots, video, unit/UI/final-relaunch result bundles, signature identity, hashes, and a local manifest;
- a `Signed Mac handoff` commit status which can be required before merge;
- immutable local Sol, handoff, and Stop controls installed from protected `main`, outside proposed branches;
- a global Codex `Stop` hook that fails closed for product-change exits except a literal user question or explicit `BLOCKED:` exit;
- merge-commit-only delivery and a post-merge `Verified release tree` attestation proving the final `main` tree exactly equals the fully verified PR-head tree.

Five independent local GPT-5.6 Sol reviews were used during bootstrap. The first rejected six false-proof paths; the second rejected nine further fail-open or deadlock paths; the third rejected twelve trust-boundary weaknesses; the fourth found fourteen additional blocking paths plus one conflicting rule; and the fifth found six PR-binding, installer, artifact-type, static-analysis, authority-route, and Stop-hook gaps. Actionable findings were converted into code and adversarial regressions. The request for cryptographic resistance to Adam's own administrator credential was resolved instead by Adam's explicit no-Touch-ID threat-model decision. This is the intended operating model: Sol supplies adversarial findings, the owner defines the authority boundary, and executable evidence decides whether each correction is real.

Harness deliberately has no repository `OPENAI_API_KEY`. Adam uses an existing paid ChatGPT/Codex subscription and blocks API keys so agents cannot accidentally create separate usage charges. The installed Sol gate therefore runs an ephemeral, read-only local Codex process through that existing authorization, posts its structured result to the pull request, and publishes the commit status. A credential-free GitHub workflow invalidates older Sol evidence whenever the PR head or acceptance text changes. Adam's Mac is never registered as a GitHub runner.

## What Harness had before this installation

| Layer | Present state | Consequence |
|---|---|---|
| Requirement | `requirement-is-the-test` says Adam’s literal sentence is the acceptance test | Strong written principle, not mechanically connected to delivery |
| Source control | Direct push to `main` is required by `.cursor/rules/ios-main-only.mdc` | No mandatory review boundary |
| GitHub protection | `main` unprotected; no rulesets | Nothing prevents an unreviewed push |
| CI | Zero GitHub Actions workflows | No clean-machine build, test, scan, or artifact check |
| Automated tests | 355 test functions by static count | Useful coverage, but not a delivery gate |
| UI tests | Zero UI-automation references | The user-visible workflow is not exercised automatically |
| Live satisfaction test | Local Hermes/Fuseki/Ollama answer test | Fail-open dependency handling; weak semantic assertions; no app UI |
| Static/security analysis | Secret-pattern pre-commit hook only | No SwiftLint, Periphery, CodeQL, or Semgrep gate |
| AI review | No Codex review workflow; no GPT-5.6 review prompt | Builder grades its own work |
| Proof | Text answer artifacts and two historical screenshots | Not required per change and not bound to the current commit |
| Handoff enforcement | Agent can stop after tests/build | Adam becomes the first real feature tester |

### The current satisfaction gate can report success without verification

`SatisfactionGateLiveTests.swift` says a pass without an artifact is invalid, but its dependency guard uses a normal `return`. Swift Testing therefore sees a successful test rather than a failure or explicit skip. The test then asserts only that the answer is nonempty, `run.success` is true, and the answer does not start with one failure prefix. A fluent but wrong, duplicated, incomplete, or visibly inaccessible answer can pass.

The saved artifacts demonstrate this weakness: different runs produced materially different answers, including duplicated evidence and a generic wrapper, while every run was marked successful. That is valuable diagnostic evidence, but it is not a feature acceptance oracle.

## The target system

```text
Adam's sentence
  -> acceptance contract committed with the change
  -> agent builds on a temporary branch
  -> local deterministic checks
       - compile
       - unit and integration tests
       - lint / unused code / security scan
  -> independent GPT-5.6 Sol review of base...head (read-only)
       - exact requirement
       - exact diff
       - risk lenses
       - required evidence
       - structured PASS / FAIL
  -> fix findings
  -> fresh Sol review of the final diff
  -> handoff verification of the final PR head on Adam's Mac
       - signed app launched from the exact commit
       - stale app instances closed
       - exact named XCUITest executed and confirmed inside xcresult
       - expected vs actual recorded
       - live Ollama + Fuseki satisfaction proof fails closed
       - window screenshot + test-time video + unit/UI xcresults attached
       - same exact visible assertion rerun after the final normal app relaunch
  -> release certificate bound to commit SHA
  -> Signed Mac handoff status published on that SHA
  -> protected merge only when every required status passes
  -> merge commit tree compared byte-for-byte with the verified PR-head tree
  -> Verified release tree status and artifact published on the final main commit
  -> only then may the agent say "done" or hand Adam the build
```

### Gate 1: merge protection

Change the repository rule from “agents push directly to `main`” to “agents own the entire branch/PR/review/merge process; Adam is never given Git homework.” This preserves the good intent—Adam does not manage branches—while creating a real review boundary.

Protect `main` with no bypass for ordinary agent credentials and allow GitHub merge commits only:

- Require a pull request.
- Require all conversations resolved.
- Dismiss approval/review state after new commits.
- Require status checks from named sources.
- Block force pushes and direct pushes.
- Require the final head SHA to be the SHA that was reviewed and verified.
- Require the merge commit tree to equal the verified head tree, then publish that attestation on the final `main` commit.

Required checks:

1. `macOS tests, SwiftLint, Periphery` on a clean hosted macOS runner.
2. `Gate script tests` for the deterministic validators.
3. `CodeQL (swift)` and `CodeQL (python)`. Harness is public, so GitHub code scanning is available without a private-repository Code Security license.
4. `GPT-5.6 Sol review` from protected-base controls in read-only mode.
5. `Acceptance contract` from a validator on the protected base, ensuring proposed code cannot weaken its own gate.
6. `Signed Mac handoff`, published only after the exact named UI test and local evidence certificate pass.

Do not treat a native Codex or Copilot review comment as a blocking approval by itself. GitHub documents that Copilot reviews are comments and do not count toward required approvals. OpenAI’s native GitHub review is optimized for serious P0/P1 findings. A custom `openai/codex-action@v1` job is the better enforcement surface because the prompt, model, effort, output artifact, and job exit state can be controlled.

### Gate 2: handoff protection

CI proves reproducibility; it does not prove the exact local experience. Harness depends on signed macOS behavior, local files, graph data, provider sessions, Fuseki/Ollama, and the possibility of stale app instances. The second gate runs on Adam’s trusted Mac against the final PR-head candidate. GitHub then permits only a two-parent merge commit and verifies that its final tree is identical to that candidate.

Every feature change must produce a proof directory keyed by commit SHA:

```text
.local-artifacts/release-gate/<commit>/
  manifest.json
  reviewed-pr-body.md
  signed-build.log
  codesign.log
  HarnessUnitTests.xcresult/
  HarnessRequirementUI.xcresult/
  HarnessFinalRelaunchUI.xcresult/
  visible-result.png
  final-relaunch-visible-result.png
  visible-requirement.mov
  satisfaction-gate/gate-<timestamp>.md
```

`manifest.json` must state:

- exact commit SHA and dirty-tree state;
- Adam’s requirement verbatim;
- expected visible outcome;
- app bundle path, signature identity, and launch PID;
- tests and checks executed, with pass/fail/skip distinguished;
- critical UI flow steps;
- the exact `HarnessUITests/<Class>/<method>` identifier confirmed as executed and passed in the result bundle;
- the same exact visible assertion confirmed again after normal relaunch of the signed candidate;
- a required live satisfaction artifact produced only when Ollama, Fuseki, and the full answer pipeline all run successfully;
- observed result and artifact paths;
- unresolved P0/P1/P2 findings;
- builder identity, independent reviewer identity, and verifier identity.

A project-local Codex `Stop` hook should reject task completion when a coding turn changed product files but no passing manifest exists for `HEAD`. OpenAI documents `Stop` hooks specifically for custom validation when a turn stops. This addresses the behavior that created the problem: the agent cannot simply return after a build and a few tests.

### The acceptance contract

Each change needs a small checked-in or PR-body contract:

```yaml
requirement_verbatim: "Adam's exact sentence"
visible_surface: "The exact app/window/tab/device"
preconditions: []
critical_flow: []
expected_visible_result: "What Adam must see"
regressions_to_check: []
required_artifacts: [screenshot, interaction_video, xcresult]
forbidden_shortcuts:
  - build success is not feature success
  - unit tests are not UI proof
  - skipped live dependencies are not a pass
```

This becomes the input to the tests, the Sol reviewer, Computer Use, and the release certificate. One requirement drives every layer; agents do not invent a different proxy test.

## Best practice for GPT-5.6 Sol code review

OpenAI’s current model guidance identifies `gpt-5.6-sol` as the frontier GPT-5.6 model and the `gpt-5.6` alias. It supports `none` through `max` reasoning effort and a separate Pro execution mode. OpenAI recommends choosing effort through representative evaluations rather than assuming the largest setting is always best. For difficult, high-value code review, `xhigh`, `max`, and Pro are candidates to benchmark against Harness’s real escaped bugs.

The review process should follow these rules:

1. **Independent context:** reviewer did not author the patch and cannot modify it.
2. **Exact revisions:** review `base_sha...head_sha`, not an ambiguous working tree.
3. **Lean, outcome-focused prompt:** goal, requirement, constraints, risk lenses, required evidence, and output schema—each stated once.
4. **Representative evidence:** include the acceptance contract, diff, directly affected callers/tests, and proof manifest. Do not dump the whole repository blindly; recent research found attention dilution as context expanded.
5. **Explicit risk lenses:** correctness, regressions, missing tests, fail-open behavior, concurrency, authorization, filesystem/TCC/signing, authority boundaries, UI state, stale-instance risk, and observability.
6. **Structured output:** machine-readable findings with severity, file, line, consequence, reproduction, and required verification.
7. **No self-fixing during review:** findings go back to the builder. A new read-only review runs after fixes.
8. **Execution arbitration:** every plausible behavioral finding becomes a test or a reproduced product observation. Textual confidence is not enough.
9. **Evaluation loop:** seed a Harness review benchmark with bugs Adam already found immediately. Compare `xhigh`, `max`, and Pro on detection, false positives, evidence quality, and cost. Pin the best configuration until a measured re-evaluation.

Suggested blocking guidance for the top-level `AGENTS.md`:

```markdown
## Review guidelines

- Treat missing proof of Adam's verbatim acceptance requirement as P1.
- Treat a test that silently returns when a required dependency is absent as P1.
- Treat build success, unit tests, or a backend success flag as insufficient proof of visible app behavior.
- Require UI automation or recorded Computer Use evidence for every changed critical user flow.
- Treat a release artifact not bound to the reviewed commit SHA as P1.
- Check macOS signing, TCC/file-permission behavior, stale app instances, provider failure states, and accepted-graph authority boundaries when relevant.
```

### Sol review gate shape

For an organization that intentionally uses API billing, `openai/codex-action@v1` can run on pull request events with pinned controls and a read-only bundle. Harness must not use that path: its credential boundary intentionally permits ChatGPT subscription authorization and blocks OpenAI API keys.

The Harness gate instead builds an inert local `base/`, `head/`, and `changes.patch` bundle; removes proposed `AGENTS.md` files as instructions; runs an ephemeral `gpt-5.6-sol` process at `max` in a read-only sandbox through Adam's existing Codex login; validates strict structured output; posts the review to the PR; and publishes the `GPT-5.6 Sol review` status on the exact head SHA. The hosted GitHub workflow does only one credential-free job: publish `pending` after every PR edit or new commit so an older local review cannot remain valid.

The status issuer, prompt, schema, validator, signed handoff, manifest parser, and Stop hook are copied into a versioned local control directory only from protected `main`. Pull-request code cannot replace those installed commands. The bootstrap installer exception was removed: after infrastructure PR #19 is independently reviewed and visibly proven under the one-time trusted-operator bootstrap, it is merged, full protection is installed and read back, and only then are the permanent controls installed from `main`.

### Trusted-operator boundary (no Touch ID)

Adam chose not to add Touch ID or a separate signing principal. His authenticated macOS session and `dblaira` GitHub administrator identity are therefore trusted operator boundaries. The system is mandatory operationally: it blocks accidental, careless, stale, unreviewed, and proposal-controlled paths. It does not claim cryptographic resistance to a malicious actor who already controls Adam's administrator credential. A stronger claim would require a separate GitHub App, another trusted principal, or user-presence signing; that is intentionally outside this gate.

Both configurations must preserve base/head identifiers, use read-only execution, and archive or publish the final review output. Benchmark `xhigh` against `max`; only consider Pro through the API if Adam later changes the explicit billing boundary.

The job should fail only on a strict schema such as:

```json
{
  "verdict": "FAIL",
  "reviewed_base": "...",
  "reviewed_head": "...",
  "acceptance_evidence_complete": false,
  "findings": [
    {
      "severity": "P1",
      "file": "...",
      "line": 25,
      "consequence": "Live verification silently passes without running",
      "required_proof": "Make dependency absence fail or explicitly skip; make the release job reject skips"
    }
  ]
}
```

## Skills and services evaluated

### Use now: no additional vendor required

| Tool or skill | Cost posture | What it should own | Limit |
|---|---|---|---|
| XCTest + Swift Testing + XCUITest | Included with Xcode | Unit, integration, UI, performance, and critical-flow tests | Tests only know encoded expectations |
| Xcode test plans / Xcode Cloud or hosted macOS Actions | Included/usage-based depending plan | Clean-machine matrix and archived results | Cloud cannot reproduce Adam’s private local state by default |
| Codex `/review` | Existing Codex capability | Local, read-only review before push | Advisory unless connected to a blocking gate |
| Local Codex exec + GPT-5.6 Sol status gate | Existing ChatGPT/Codex subscription | Structured, commit-bound independent review without an API key or self-hosted runner | Requires trusted local invocation; GitHub invalidates stale evidence but cannot execute the model |
| OpenAI Codex GitHub Action + GPT-5.6 Sol | API usage: Sol is currently $5/M input tokens and $30/M output tokens | Reproducible, independent review of every diff | Model review is probabilistic and needs execution evidence |
| Codex Computer Use QA | Existing/included capability depending plan | Click the real app, record expected vs actual, produce repro evidence | Must be given the exact environment and hero flows |
| Codex `Stop` hook | No service fee | Prevent the coding agent from ending without a valid proof manifest | Codex lifecycle guard, not a universal Git/GitHub control |
| SwiftLint | Open source | Swift conventions and selected unsafe patterns | Style/static rules, not feature correctness |
| Periphery | Open source | Unused Swift code and dead paths | Requires reliable project indexing |
| swift-snapshot-testing | Open source | Visual and value snapshots | Stable runner configuration required for image comparisons |
| CodeQL for Swift | Free for this public repository | Security/reliability queries on macOS | Static analysis cannot prove the user flow |
| Semgrep | Open-source CLI plus paid platform options | Custom Swift rules and security patterns | Swift rule depth varies by rule set |
| Qodo PR-Agent | Open source; model/API costs remain | Alternative self-hosted PR review workflow | Additional reviewer is useful only if benchmarked against escapes |

### Paid automated reviewers: useful as a benchmark or second opinion

| Service | Current public price/capability | Best use for Harness | Important limit |
|---|---|---|---|
| CodeRabbit | Pro $24/developer/month billed annually; open-source repositories receive paid features free | Trial against Harness’s escaped-bug corpus; PR summaries, lint/SAST integration | Another probabilistic reviewer; do not substitute it for UI proof |
| Greptile | Starter free with 50 credits/month for one active developer; Pro $30/seat/month | Repository-graph-aware second review | Credit model and same AI-review limitations |
| GitHub Copilot code review | Available on paid Copilot plans; automatic review supported | Low-friction second signal and custom instructions | GitHub explicitly says its review is a comment and cannot satisfy required approval or block merge |
| Claude Code Review | Research preview for Team/Enterprise; average $15–25 per PR | Multi-agent adversarial second pass on high-risk changes | Advisory, best-effort, and failed reviews do not block merge |
| GitHub Code Quality | Public preview now; billing begins 2026-07-20 | Reliability/maintainability signal and ruleset threshold | Model switching unsupported; imminent paid usage; not feature verification |

Recommendation: do not buy three overlapping AI reviewers. First build the Harness escaped-bug benchmark and run GPT-5.6 Sol, CodeRabbit, Greptile, and Copilot against the same set. Keep at most one second reviewer if it finds important bugs Sol misses without flooding the review with noise.

### Paid human review and feature-testing services

| Service | Current public offer | Appropriate role | Inappropriate role |
|---|---|---|---|
| HackerOne Code / PullRequest | $129/developer/month; AI risk selection plus human reviewers; vendor says typical coverage is 30–40% of PRs | Security-sensitive or architectural human review | Not an every-change release gate under Smart Review Selection |
| Pixelwright Digital | $500 flat Apple-platform audit | Focused Swift/SwiftUI/App Store launch-risk triage | Point-in-time code audit, not proof that every feature works |
| AtalayaSoft | €1,200 scan; €3,500 full audit; €7,500+ audit and fix | Deep native Apple audit using Instruments, Accessibility Inspector, and other Apple tooling | Periodic independent audit, not continuous delivery control |
| BrowserStack App Automate/App Live | Free trial includes mobile minutes; paid real-device plans | iOS device/OS compatibility and visual testing | Does not verify Harness’s local macOS/graph/provider environment |
| Testlio | Managed quote; human and automated iOS, desktop, and customer-journey testing | Major-release exploratory testing across devices and operating systems | Excessive as the first fix for an absent local gate |

Best paid use: purchase a human Apple-platform audit after the internal gate is installed, then convert every valid finding into a permanent automated check. Buying an audit before establishing the gate produces a report but does not stop the destructive handoff pattern.

## Recommended adoption order

1. Freeze feature handoffs. Research/documentation work may continue; no build is presented as ready.
2. Replace the direct-to-`main` rule with agent-owned PRs and protected `main`. Adam still receives no branch or Git homework.
3. Add the acceptance-contract template and require it for changed product behavior.
4. Make existing live tests fail closed in release runs. Explicit skips must make the release gate fail, even if they remain permissible in ordinary development.
5. Add XCUITest critical flows for the Harness macOS surface and bind screenshots/video to the test result.
6. Add clean macOS build/tests, SwiftLint, Periphery, and CodeQL to GitHub Actions.
7. Add the read-only GPT-5.6 Sol review job and seed its evaluation with Adam’s known escaped bugs.
8. Add the Mac-local handoff verifier and release manifest.
9. Add the Codex `Stop` hook so an agent cannot return “done” without current proof.
10. Run one independent human Apple audit; convert accepted findings into tests/rules.

## Contrarian views and risks

- **More AI reviewers can create more verification debt.** An industrial study of automated review found useful comments but also faulty or irrelevant feedback and longer PR closure. The solution is a measured second signal, not reviewer accumulation.
- **Frontier reviewer models still miss many issues.** SWE-PRBench reported only 15–31% detection of human-flagged issues in its tested configurations. This preprint is not the final word and does not test GPT-5.6 Sol specifically, but it strongly rejects model-only release decisions.
- **More context can hurt.** SWE-PRBench found declining performance as context expanded. Give Sol the exact diff, acceptance contract, affected code, and evidence; do not assume a repository dump improves judgment.
- **Execution helps only when tests are meaningful.** Peer-reviewed work found execution-guided verification reduced errors, but shallow suites could still accept buggy implementations. This is why Harness needs UI flows from Adam’s requirement, not only current unit tests.
- **A self-hosted Mac runner is dangerous on a public repository.** Untrusted fork code must never execute on Adam’s Mac. Use GitHub-hosted macOS for public PR checks. Keep local handoff verification behind trusted local execution, or make the repository private and tightly restrict runner triggers before considering a self-hosted GitHub runner.
- **Snapshot tests can bless the wrong design.** They detect change, not correctness. Reference updates require review against the acceptance contract.
- **A human audit does not verify every build.** It is a periodic deep inspection whose findings must be converted into permanent gates.

## Decisions made for the installed gate

1. Keep the public repository on GitHub-hosted macOS runners. Adam's Mac is used only for trusted, local signed-app handoff verification and is not registered as a self-hosted runner.
2. Start with the macOS Harness surface because that is the current handoff surface. iOS proof remains a separate extension when an iOS requirement changes.
3. Seed the review guidance with the observed escaped-bug classes: fail-open dependency checks, stale-app verification, folder/TCC/signing problems, provider/auth failures, silent waits, and accepted-graph authority confusion.
4. Preserve Adam's no-API-key boundary: use the existing ChatGPT/Codex subscription for local Sol review, never add a repository OpenAI key as a shortcut, and never register Adam's Mac as a public-repository runner.
5. Bind acceptance to a checked-in contract digest plus the matching PR sections; PR edits invalidate both local statuses and in-flight issuers re-read the digest before publishing.
6. Parse evidence again from the trusted verifier: xcresults, named screenshot attachments, PNG/QuickTime formats, live Fuseki markers, app CDHash/team, PID path, current Sol status, and artifact hashes are never accepted from manifest labels alone.
7. Do not add another paid AI-review vendor before GPT-5.6 Sol is evaluated on Harness's escaped bugs. A human Apple audit remains the highest-value paid second layer after the internal gate is operational.
8. Keep Adam's administrator identity as the explicit trusted-operator boundary; do not add Touch ID unless Adam later asks for malicious-admin resistance.

## Sources

### OpenAI primary sources

- [GPT-5.6 Sol model](https://developers.openai.com/api/docs/models/gpt-5.6-sol) — model identity, capabilities, context, and token pricing.
- [GPT-5.6 model guidance](https://developers.openai.com/api/docs/guides/latest-model) — reasoning effort, Pro mode, lean prompts, boundaries, evidence, and representative evaluation.
- [Codex code review](https://learn.chatgpt.com/docs/code-review) — exact review scope, `/review`, and read-only reviewer behavior.
- [Codex code review in GitHub](https://learn.chatgpt.com/docs/third-party/github) — automatic review, `AGENTS.md` review guidelines, and P0/P1 focus.
- [Codex GitHub Action](https://learn.chatgpt.com/docs/github-action) — CI review workflow, permissions, prompt files, model/effort selection, and saved output.
- [openai/codex-action](https://github.com/openai/codex-action) — source and security model for a custom PR bot.
- [Codex hooks](https://learn.chatgpt.com/docs/hooks) — deterministic lifecycle validation and `Stop` hook behavior.
- [QA your app with Computer Use](https://learn.chatgpt.com/use-cases/qa-your-app-with-computer-use) — real-flow QA, repro steps, expected/actual, severity, and test-plan inputs.
- [Codex Security change review](https://learn.chatgpt.com/docs/security/plugin/code-changes) — exact base/head diff review and CI artifact guidance.

### GitHub and Apple primary sources

- [GitHub ruleset rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) — required PRs, checks, scans, coverage, and force-push protection.
- [GitHub protected branches](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches) — required reviews/checks and no-bypass controls.
- [GitHub secure use reference](https://docs.github.com/en/actions/reference/security/secure-use) — why self-hosted runners should almost never be attached to public repositories.
- [GitHub Copilot code review](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/request-a-code-review/use-code-review) — automatic reviews, custom instructions, and non-blocking comment status.
- [CodeQL supported languages](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/) — Swift support and macOS requirement.
- [GitHub Advanced Security billing](https://docs.github.com/en/billing/concepts/product-billing/github-advanced-security) — free public-repository subset and paid private-repository security.
- [Apple testing overview](https://developer.apple.com/documentation/xcode/testing) — unit/integration/UI test pyramid and XCUIAutomation.
- [Adding tests to an Xcode project](https://developer.apple.com/documentation/xcode/adding-tests-to-your-xcode-project) — UI tests that reproduce critical user activities and reported bugs.
- [Xcode Cloud](https://developer.apple.com/xcode-cloud/) — clean CI, parallel testing, delivery, and feedback.

### Open-source tools and commercial services

- [SwiftLint](https://github.com/realm/SwiftLint)
- [Periphery](https://github.com/peripheryapp/periphery)
- [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing)
- [Semgrep](https://github.com/semgrep/semgrep)
- [Qodo PR-Agent](https://github.com/qodo-ai/pr-agent)
- [CodeRabbit pricing](https://www.coderabbit.ai/pricing)
- [Greptile pricing](https://www.greptile.com/pricing)
- [Claude Code Review](https://code.claude.com/docs/en/code-review)
- [HackerOne Code / PullRequest pricing](https://www.pullrequest.com/pricing/)
- [Pixelwright Apple-platform code audit](https://pixelwrightdigital.com/)
- [AtalayaSoft native iOS audit](https://www.atalayasoft.com/services/vibe-code-audit-ios)
- [BrowserStack trial and device testing](https://www.browserstack.com/support/faq/plans-pricing/plans/what-do-i-get-with-a-free-trial)
- [Testlio real-device and desktop testing](https://www.testlio.com/real-device-testing)

### Research and counterevidence

- [SWE-PRBench](https://arxiv.org/abs/2603.26130) — human-annotated PR review benchmark and context-ablation results; 2026 preprint.
- [Automated Code Review in Practice](https://arxiv.org/abs/2412.18531) — industrial adoption outcomes and drawbacks; preprint.
- [Are LLMs reliable code reviewers?](https://link.springer.com/article/10.1007/s10515-026-00638-5) — peer-reviewed evidence on false positives/negatives and execution-guided verification.
- [Martian Code Review Bench](https://github.com/withmartian/code-review-benchmark) — open benchmark, methodology, and online/offline divergence.

## Rerun inputs

```yaml
workflow: firecrawl-deep-research
topic: verified build, independent code review, feature QA, GPT-5.6 Sol review, and Harness gap analysis
depth: exhaustive
output: markdown report
constraint: Firecrawl CLI was installed but FIRECRAWL_API_KEY was unavailable; equivalent web research was used with primary-source preference
local_evidence:
  - live GitHub repository settings via gh
  - AGENTS.md and .cursor rules
  - project.yml
  - test inventory
  - SatisfactionGateLiveTests.swift
  - existing proof artifacts
```
