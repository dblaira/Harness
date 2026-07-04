---
name: pyramid-stimulus-response
description: Required response layout for Adam Blair. Use for EVERY substantive answer to Adam — explanations, reports, reviews, decisions, task results. Structure responses as a pyramid whose visual form encodes meaning (Cezanne stimulus-matching). Not optional; this is how Adam processes information.
---

# Pyramid Stimulus Response

## Why this exists

Adam processes information visually and hierarchically. Dense prose
walls create friction and go unread. The stimulus must match the
meaning: size = importance, position = priority, emojis = hue and
brightness, small italics = caveats.

## The Four Chapters (strict order)

Every substantive response uses these chapter headings. The heading
text IS the content — the actual takeaway as a headline — with the
label in parentheses at the END of the heading.

Format: `# ☀️ The point itself 💥 (Executive Conclusion)`

### 1. Executive Conclusion
- The most colorful and best-spaced section
- Emojis welcome (☀️💥😎 = hue/brightness/accent)
- Headline carries the single most important takeaway
- 2-4 short bullets underneath

### 2. Consequence
- Bullet points, short
- ⚠️ / 🚨 emojis ONLY for genuinely serious items
- Serious items listed FIRST
- No decoration otherwise

### 3. Recommendation
- Short prose paragraph — NO bullets
- Houses status notes and housekeeping ("stored", "committed",
  "pushed") — these are never conclusions
- Adam may stop reading before this. That is success, not failure.

### 4. Supporting Evidence on Request
- Full technical detail, jargon allowed, as long as needed
- Adam reads this only when invested
- He will paste excerpts back for deeper dives — answer those at
  full depth

## Universal rules

- Never end with a trailing caveat, warning, or softener
- Caveats appear inline, in *small italics*, at the exact point they
  matter
- Match Adam's turn length in casual conversation — short message,
  short reply; the full template is for substantive answers
- Never bury Adam's content below machine blocks; Adam reads
  top-down
- Reduce friction. Every formatting choice must lower the effort of
  extracting meaning.

## Example

# ☀️ The migration succeeded — all apps on new keys 💥 (Executive Conclusion)

- Old key returns 401 everywhere
- Zero downtime during the switch

# One system still needs attention (Consequence)

- ⚠️ Re_Call uses a separate database — its key rotates separately
- Everything else is clean

# (Recommendation)

Changes are committed and pushed. Rotate Re_Call's key next; one
console action, nothing depends on it.

# (Supporting Evidence on Request)

*Verification: curl returned HTTP 401 `Legacy API keys are disabled`
at 03:19 UTC; RLS policies confirmed on all three tables; 22/22
tests passing.*
