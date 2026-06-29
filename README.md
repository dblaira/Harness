# Harness

A native macOS + iOS app that puts Adam's personal ontology — his confirmed
beliefs, axioms, and the Adam Pattern — in front of any LLM, so every answer is
shaped by his own thinking and names the rule it used.

**The suite:** Understood (data) · Re_Call (engine) · SAVY + iOS (surfaces) ·
**Harness** (this — houses all info + controls the LLM through these constraints).

## How it works
- `Packages/OntologyKit` ships the live `.ttl` graph and loads it.
- The app sends your question prefixed with the ontology as a system prompt.
- It borrows the CLIs you already pay for (Codex = ChatGPT sub, Grok = xAI sub)
  or a direct Claude API key — no token copying, no re-auth.

## Build
```sh
xcodegen generate          # regenerate the Xcode project from project.yml
xcodebuild -project Harness.xcodeproj -scheme Harness \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

`project.yml` is the source of truth; `Harness.xcodeproj` is generated and gitignored.
