#!/usr/bin/env python3
"""Replace proposal-owned test implementations with protected-base copies."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path


DEFAULT_MAPPINGS = (
    ("Tests/HarnessTests", "Tests/HarnessTests"),
    ("Packages/OntologyKit/Tests", "Packages/OntologyKit/Tests"),
)


def copy_protected_tests(
    trusted_root: Path,
    proposed_root: Path,
    mappings: tuple[tuple[str, str], ...] = DEFAULT_MAPPINGS,
) -> list[str]:
    errors: list[str] = []
    trusted_root = trusted_root.resolve()
    proposed_root = proposed_root.resolve()
    if trusted_root == proposed_root:
        return ["trusted and proposed test roots must be different"]
    for source_name, destination_name in mappings:
        source = trusted_root / source_name
        destination = proposed_root / destination_name
        if not source.is_dir():
            errors.append(f"protected test source is missing: {source_name}")
            continue
        if any(path.is_symlink() for path in source.rglob("*")):
            errors.append(f"protected test source contains a symlink: {source_name}")
            continue
        if destination.is_symlink() or (
            destination.exists() and not destination.is_dir()
        ):
            errors.append(f"proposed test destination is not a directory: {destination_name}")
            continue
        if destination.exists() and any(path.is_symlink() for path in destination.rglob("*")):
            errors.append(f"proposed test destination contains a symlink: {destination_name}")
            continue
        destination.mkdir(parents=True, exist_ok=True)
        for protected_path in source.rglob("*"):
            relative = protected_path.relative_to(source)
            proposed_path = destination / relative
            if protected_path.is_dir():
                proposed_path.mkdir(parents=True, exist_ok=True)
                continue
            proposed_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(protected_path, proposed_path, follow_symlinks=False)
            os.chmod(proposed_path, 0o444)
    return errors


def verify_protected_tests(
    trusted_root: Path,
    proposed_root: Path,
    mappings: tuple[tuple[str, str], ...] = DEFAULT_MAPPINGS,
) -> list[str]:
    errors: list[str] = []
    for source_name, destination_name in mappings:
        source = trusted_root.resolve() / source_name
        destination = proposed_root.resolve() / destination_name
        if not source.is_dir() or not destination.is_dir():
            errors.append(f"protected test implementation set is missing: {source_name}")
            continue
        for protected_path in source.rglob("*"):
            if not protected_path.is_file():
                continue
            proposed_path = destination / protected_path.relative_to(source)
            if (
                not proposed_path.is_file()
                or proposed_path.is_symlink()
                or proposed_path.read_bytes() != protected_path.read_bytes()
            ):
                errors.append(
                    f"protected test implementation changed: {destination_name}/{protected_path.relative_to(source)}"
                )
    return errors


def parse_mapping(value: str) -> tuple[str, str]:
    source, separator, destination = value.partition("=")
    if not separator or not source or not destination:
        raise argparse.ArgumentTypeError("mapping must be PROTECTED_PATH=PROPOSED_PATH")
    if Path(source).is_absolute() or Path(destination).is_absolute():
        raise argparse.ArgumentTypeError("mapping paths must be relative")
    if ".." in Path(source).parts or ".." in Path(destination).parts:
        raise argparse.ArgumentTypeError("mapping paths may not escape their roots")
    return source, destination


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trusted-root", required=True, type=Path)
    parser.add_argument("--proposed-root", required=True, type=Path)
    parser.add_argument("--mapping", action="append", type=parse_mapping)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    mappings = tuple(args.mapping) if args.mapping else DEFAULT_MAPPINGS
    operation = verify_protected_tests if args.verify_only else copy_protected_tests
    errors = operation(args.trusted_root, args.proposed_root, mappings)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    verb = "Verified" if args.verify_only else "Installed"
    print(f"{verb} {len(mappings)} protected test implementation set(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
