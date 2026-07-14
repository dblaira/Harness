#!/usr/bin/env python3
"""Build a protected inventory of Swift test identifiers."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


FUNCTION_MODIFIERS = {
    "class", "fileprivate", "final", "internal", "mutating", "nonisolated",
    "open", "override", "package", "private", "public", "static",
}


def declared_function(line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if not stripped or stripped.startswith("//"):
        return None
    marker = "func "
    index = stripped.find(marker)
    if index < 0:
        return None
    prefix = stripped[:index]
    if prefix and not prefix.startswith("@") and not set(prefix.split()).issubset(FUNCTION_MODIFIERS):
        return None
    tail = stripped[index + len(marker):].lstrip()
    name, separator, _ = tail.partition("(")
    name = name.strip()
    if not separator or not name or not name[0].islower() or not name.replace("_", "a").isalnum():
        return None
    return name, prefix


def identifiers(text: str) -> set[str]:
    results: set[str] = set()
    pending_test_annotation = False
    pending_annotation_depth = 0
    for line in text.splitlines():
        declaration = declared_function(line)
        if declaration:
            name, prefix = declaration
            if pending_test_annotation or "@Test" in prefix or name.startswith("test"):
                results.add(name)
            pending_test_annotation = False
            pending_annotation_depth = 0
        elif line.lstrip().startswith("@"):
            pending_test_annotation = pending_test_annotation or "@Test" in line
            pending_annotation_depth += line.count("(") - line.count(")")
        elif pending_annotation_depth > 0:
            pending_annotation_depth += line.count("(") - line.count(")")
        elif line.strip() and not line.lstrip().startswith("//"):
            pending_test_annotation = False
    return results


def from_source_root(root: Path) -> set[str]:
    return {
        name
        for path in root.rglob("*.swift")
        for name in identifiers(path.read_text(encoding="utf-8"))
    }


def from_git(repo_root: Path, ref: str, tree_path: str) -> set[str]:
    listing = subprocess.run(
        ["/usr/bin/git", "ls-tree", "-r", "--name-only", ref, "--", tree_path],
        cwd=repo_root, text=True, capture_output=True, check=False,
    )
    if listing.returncode:
        raise ValueError(listing.stderr.strip() or "cannot list protected test sources")
    results: set[str] = set()
    for path in listing.stdout.splitlines():
        if not path.endswith(".swift"):
            continue
        content = subprocess.run(
            ["/usr/bin/git", "show", f"{ref}:{path}"],
            cwd=repo_root, text=True, capture_output=True, check=False,
        )
        if content.returncode:
            raise ValueError(content.stderr.strip() or f"cannot read protected test source: {path}")
        results.update(identifiers(content.stdout))
    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--source-root", type=Path)
    source.add_argument("--git-ref")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--tree-path", default="Tests/HarnessTests")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        tests = from_source_root(args.source_root) if args.source_root else from_git(
            args.repo_root, args.git_ref, args.tree_path
        )
    except (OSError, ValueError) as error:
        print(f"cannot build protected test inventory: {error}", file=sys.stderr)
        return 1
    if not tests:
        print("protected test inventory is empty", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(sorted(tests), indent=2) + "\n", encoding="utf-8")
    print(f"Protected Swift test inventory contains {len(tests)} tests.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
