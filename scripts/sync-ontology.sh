#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CANONICAL_DIR="${ONTOLOGY_ACCEPTED_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology/accepted}"
RESOURCE_DIR="$REPO_ROOT/Packages/OntologyKit/Sources/OntologyKit/Resources"
HEADER="# GENERATED COPY — edit canonical version in Ontology/accepted/ instead."

if [[ ! -d "$CANONICAL_DIR" ]]; then
  echo "Missing canonical ontology folder: $CANONICAL_DIR" >&2
  exit 1
fi

mkdir -p "$RESOURCE_DIR"
find "$RESOURCE_DIR" -maxdepth 1 -type f -name "*.ttl" -delete

found=0
while IFS= read -r -d '' source_file; do
  found=1
  destination_file="$RESOURCE_DIR/$(basename "$source_file")"
  {
    printf '%s\n\n' "$HEADER"
    cat "$source_file"
  } > "$destination_file"
done < <(find "$CANONICAL_DIR" -maxdepth 1 -type f -name "*.ttl" -print0 | sort -z)

if [[ "$found" -eq 0 ]]; then
  echo "No .ttl files found in canonical ontology folder: $CANONICAL_DIR" >&2
  exit 1
fi

echo "Synced ontology copies from $CANONICAL_DIR"
