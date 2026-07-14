#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CANONICAL_DIR="${ONTOLOGY_ACCEPTED_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/Main/Ontology/accepted}"
RESOURCE_DIR="$REPO_ROOT/Packages/OntologyKit/Sources/OntologyKit/Resources"
HEADER="# GENERATED COPY — edit canonical version in Ontology/accepted/ instead."

# The canonical folder lives in iCloud and is absent on fresh machines and
# builder-agent environments. The committed copies in Resources/ are valid;
# a missing canonical folder must never fail the build (WO-B / recovery WO-6a).
if [[ ! -d "$CANONICAL_DIR" ]]; then
  echo "warning: canonical ontology folder not found ($CANONICAL_DIR); keeping committed copies in Resources/" >&2
  exit 0
fi

# Collect sources BEFORE touching Resources so an empty canonical folder
# also keeps the committed copies instead of deleting them.
source_files=()
while IFS= read -r -d '' source_file; do
  source_files+=("$source_file")
done < <(find "$CANONICAL_DIR" -maxdepth 1 -type f -name "*.ttl" -print0 | sort -z)

if [[ "${#source_files[@]}" -eq 0 ]]; then
  echo "warning: no .ttl files in canonical ontology folder ($CANONICAL_DIR); keeping committed copies in Resources/" >&2
  exit 0
fi

mkdir -p "$RESOURCE_DIR"
find "$RESOURCE_DIR" -maxdepth 1 -type f -name "*.ttl" -delete

for source_file in "${source_files[@]}"; do
  destination_file="$RESOURCE_DIR/$(basename "$source_file")"
  {
    printf '%s\n\n' "$HEADER"
    IFS= read -r first_line < "$source_file" || true
    if [[ "${first_line:-}" == "$HEADER" ]]; then
      # Canonical files may themselves be generated exports. Keep this sync
      # idempotent instead of adding another generated-copy header per build.
      tail -n +2 "$source_file" | sed '1{/^$/d;}'
    else
      cat "$source_file"
    fi
  } > "$destination_file"
done

echo "Synced ${#source_files[@]} ontology copies from $CANONICAL_DIR"
