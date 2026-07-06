---
name: bitter-lesson
description: Apply Rich Sutton's "Bitter Lesson" to software design. Ensure systems favor computational scale, data-driven learning, and generalized patterns over hand-crafted heuristics. Use when designing logic, algorithms, or rules.
---

# Bitter Lesson

You must apply Rich Sutton's **Bitter Lesson** to software architecture and logic design. Consistently prioritize general-purpose methods that leverage computation and learning from data over complex, hand-crafted, human-engineered rules.

## Core Architectural Principles

1. **Favor learning from data over hardcoded rules:**
   - Let actual patterns in usage or dataset examples drive system behavior. Avoid writing rigid, nested conditional blocks (`if-else` structures) based on human intuition.
2. **Build generalizable systems:**
   - Focus on creating general conventions, abstractions, or configuration files (e.g., a conventions document) instead of correcting 50 individual instances manually.
3. **Embrace computation over manual domain knowledge:**
   - Leverage AI models, search, and algorithmic computation to surface insights that humans might miss, rather than building elaborate domain-specific heuristics.
4. **Accept surprises:**
   - When the empirical data or computational results contradict intuition, trust the data. Do not force the AI or system to conform to hardcoded human preconceptions.

## Review Protocol

- When designing database structures, decision trees, or recommendation engines, review the design and ask: *"Is this design relying on hand-crafted rules, or does it leverage computational scale and learning from data?"*
- Redesign overly rigid logic into learning-based or search-based paradigms whenever feasible.
