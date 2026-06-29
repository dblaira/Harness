#!/usr/bin/env python3
"""Momentum gate: every answer passes through here before Adam sees it.
Enforces his two hard rules — plain words, short length."""

import re
import sys

WORD_CAP = 20  # momentum-metric: short keeps momentum

# words Adam doesn't use — jargon that ruins the moment (judgment-over-vocab)
JARGON = {
    "axiom", "constraint", "ontology", "disposition", "BFO", "schema",
    "A/B", "instantiate", "leverage", "paradigm", "framework", "modular",
    "heuristic", "semantic", "vocabulary bridge", "create-desire",
}


def gate(answer: str) -> str:
    flags = []

    words = answer.split()
    if len(words) > WORD_CAP:
        flags.append(f"TOO LONG: {len(words)} words (cap {WORD_CAP})")

    hits = [w for w in words if w.strip(".,").lower() in JARGON]
    if hits:
        flags.append(f"JARGON: {', '.join(hits)}")

    if flags:
        return "BLOCKED — " + " | ".join(flags) + "\nRewrite shorter, plain words."
    return "PASS: " + answer


if __name__ == "__main__":
    text = " ".join(sys.argv[1:]) or sys.stdin.read()
    print(gate(text))
