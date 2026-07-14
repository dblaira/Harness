#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${HARNESS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT_DIR"
[[ $# -eq 0 ]] || {
  echo "usage: $0" >&2
  exit 2
}
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
SHA="$(git rev-parse HEAD)"
OUTPUT_DIR="$ROOT_DIR/.local-artifacts/github-protection/$SHA"
mkdir -p "$OUTPUT_DIR"

gh api -X PATCH "repos/$REPO" \
  -F allow_merge_commit=true \
  -F allow_squash_merge=false \
  -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true > "$OUTPUT_DIR/repository.json"

python3 - "$OUTPUT_DIR/protection-request.json" <<'PY'
import json, sys
contexts = [
    "Trusted hosted verification",
    "GPT-5.6 Sol review",
    "Signed Mac handoff",
]
payload = {
    "required_status_checks": {
        "strict": True,
        "contexts": contexts,
    },
    "enforce_admins": True,
    "required_pull_request_reviews": {
        "dismiss_stale_reviews": True,
        "require_code_owner_reviews": False,
        "required_approving_review_count": 0,
        "require_last_push_approval": False,
    },
    "restrictions": None,
    "required_conversation_resolution": True,
    "required_linear_history": False,
    "allow_force_pushes": False,
    "allow_deletions": False,
    "block_creations": False,
    "required_signatures": False,
    "lock_branch": False,
    "allow_fork_syncing": True,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY
gh api -X PUT "repos/$REPO/branches/main/protection" \
  --input "$OUTPUT_DIR/protection-request.json" > "$OUTPUT_DIR/protection.json"

printf '%s\n' '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}' \
  > "$OUTPUT_DIR/actions-request.json"
gh api -X PUT "repos/$REPO/actions/permissions" \
  --input "$OUTPUT_DIR/actions-request.json" > "$OUTPUT_DIR/actions-update.json"
printf '%s\n' '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":[]}' \
  > "$OUTPUT_DIR/selected-actions-request.json"
gh api -X PUT "repos/$REPO/actions/permissions/selected-actions" \
  --input "$OUTPUT_DIR/selected-actions-request.json" > "$OUTPUT_DIR/selected-actions-update.json"
printf '%s\n' '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}' \
  > "$OUTPUT_DIR/workflow-permissions-request.json"
gh api -X PUT "repos/$REPO/actions/permissions/workflow" \
  --input "$OUTPUT_DIR/workflow-permissions-request.json" > "$OUTPUT_DIR/workflow-permissions-update.json"
gh api "repos/$REPO/actions/permissions" > "$OUTPUT_DIR/actions.json"
gh api "repos/$REPO/actions/permissions/selected-actions" > "$OUTPUT_DIR/selected-actions.json"
gh api "repos/$REPO/actions/permissions/workflow" > "$OUTPUT_DIR/workflow-permissions.json"
gh api "repos/$REPO/actions/runners" > "$OUTPUT_DIR/runners.json"
gh api "repos/$REPO/branches/main/protection" > "$OUTPUT_DIR/protection-readback.json"
gh api "repos/$REPO" > "$OUTPUT_DIR/repository-readback.json"

EVIDENCE_DIR="$OUTPUT_DIR" python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ["EVIDENCE_DIR"])
repo = json.loads((root / "repository-readback.json").read_text())
protection = json.loads((root / "protection-readback.json").read_text())
actions = json.loads((root / "actions.json").read_text())
selected_actions = json.loads((root / "selected-actions.json").read_text())
workflow_permissions = json.loads((root / "workflow-permissions.json").read_text())
runners = json.loads((root / "runners.json").read_text())
contexts = set(protection["required_status_checks"]["contexts"])
required = {
    "Trusted hosted verification", "GPT-5.6 Sol review", "Signed Mac handoff",
}
errors = []
if contexts != required: errors.append("required status contexts differ")
if protection.get("required_status_checks", {}).get("strict") is not True: errors.append("strict status checks are disabled")
if not protection.get("enforce_admins", {}).get("enabled"): errors.append("admins are not enforced")
if protection.get("allow_force_pushes", {}).get("enabled"): errors.append("force pushes are allowed")
if protection.get("allow_deletions", {}).get("enabled"): errors.append("branch deletion is allowed")
if not protection.get("required_pull_request_reviews"): errors.append("pull requests are not required")
if not protection.get("required_conversation_resolution", {}).get("enabled"): errors.append("conversation resolution is not required")
if not repo.get("allow_merge_commit") or repo.get("allow_squash_merge") or repo.get("allow_rebase_merge"):
    errors.append("repository does not enforce merge-commit-only delivery")
if actions.get("sha_pinning_required") is not True: errors.append("Actions SHA pinning is not required")
if actions.get("allowed_actions") != "selected": errors.append("Actions are not restricted")
if workflow_permissions.get("default_workflow_permissions") != "read": errors.append("workflow tokens are not read-only by default")
if workflow_permissions.get("can_approve_pull_request_reviews") is not False: errors.append("workflows can approve pull requests")
if selected_actions.get("github_owned_allowed") is not True or selected_actions.get("verified_allowed") is not False:
    errors.append("selected Actions policy differs")
if runners.get("total_count") != 0: errors.append("public repository has a self-hosted runner")
attestation = {
    "status": "PASS" if not errors else "FAIL",
    "phase": "full",
    "required_contexts": sorted(contexts),
    "merge_commit_only": repo.get("allow_merge_commit") and not repo.get("allow_squash_merge") and not repo.get("allow_rebase_merge"),
    "force_pushes_blocked": not protection.get("allow_force_pushes", {}).get("enabled"),
    "admins_enforced": protection.get("enforce_admins", {}).get("enabled"),
    "self_hosted_runner_count": runners.get("total_count"),
    "actions_sha_pinning": actions.get("sha_pinning_required"),
    "errors": errors,
}
(root / "installation-attestation.json").write_text(json.dumps(attestation, indent=2) + "\n")
if errors:
    raise SystemExit("; ".join(errors))
print(json.dumps(attestation, indent=2))
PY

echo "Installed and read back full protected main for $REPO at $SHA."
