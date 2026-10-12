#!/usr/bin/env bash
# Builds the review inputs in four directories, so the agent can change nothing a later step trusts:
# - unreal-agent-work: the agent's workspace and Bash working directory, read-only in the
#   sandbox. The runner loads .env and .harness/skills from it, so it is not the checkout.
# - unreal-agent-inputs: diff, base-branch AGENTS.md, PR title and description; read-only.
# - unreal-agent-state: the runner's session store; the only writable grant besides /tmp.
# - unreal-agent: profile, task, criteria, logs, and review; never granted to the sandbox.
set -euo pipefail

work="$RUNNER_TEMP/unreal-agent-work"
inputs="$RUNNER_TEMP/unreal-agent-inputs"
state="$RUNNER_TEMP/unreal-agent-state"
trusted="$RUNNER_TEMP/unreal-agent"
defaults="$GITHUB_ACTION_PATH/defaults"
mkdir -p "$work" "$inputs" "$state" "$trusted"

merge_base=$(git merge-base "$BASE_SHA" "$HEAD_SHA")
# Lockfiles are left out of the diff: they are large and rarely worth review tokens.
paths=(-- . ':(exclude,glob)**/uv.lock' ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/pnpm-lock.yaml'
  ':(exclude,glob)**/yarn.lock' ':(exclude,glob)**/Cargo.lock' ':(exclude,glob)**/go.sum' ':(exclude,glob)**/poetry.lock')
# Extra excludes from the diff-exclude input: one git pathspec per line, blank lines ignored.
# This script adds the :(exclude) magic, so an entry must not start with its own magic.
while IFS= read -r spec; do
  spec="${spec#"${spec%%[![:space:]]*}"}"
  spec="${spec%"${spec##*[![:space:]]}"}"
  if [ -z "$spec" ]; then continue; fi
  if [[ "$spec" == :* ]]; then
    echo "::error::diff-exclude entry '$spec' must be a plain pathspec, without a leading ':'."
    exit 1
  fi
  paths+=(":(exclude)$spec")
done <<< "${DIFF_EXCLUDE:-}"
git diff --stat "$merge_base" "$HEAD_SHA" "${paths[@]}" > "$inputs/changed-files.txt"
git diff --unified=10 "$merge_base" "$HEAD_SHA" "${paths[@]}" > "$inputs/pr.diff"

# Prompt, criteria, and rules come from the base branch, so a PR cannot weaken its own review.
# A file missing on the base branch falls back to this action's default.
from_base() { # repository path, fallback file, destination
  if git cat-file -e "$BASE_SHA:$1" 2>/dev/null; then
    echo "Using $1 from the base branch."
    git show "$BASE_SHA:$1" > "$3"
  else
    cp "$2" "$3"
  fi
}
from_base .github/unreal-agent/pr-review.md "$defaults/pr-review.md" "$trusted/pr-review.md"
from_base .github/unreal-agent/review-criteria.md "$defaults/review-criteria.md" "$trusted/review-criteria.md"
from_base AGENTS.md "$defaults/AGENTS.md" "$inputs/AGENTS.md"

# The PR title and description are author-written. They go to read-only files, not into
# the task text, so no text in them can pass for part of the task.
printf '%s\n' "$PR_TITLE" > "$inputs/pr-title.txt"
printf '%s\n' "$PR_BODY" > "$inputs/pr-description.txt"
{
  cat "$trusted/pr-review.md"
  printf '\nPR_CONTEXT:\n- Number: #%s\n- Base commit: %s\n- Head commit: %s\n' "$PR_NUMBER" "$merge_base" "$HEAD_SHA"
  printf -- '- Repository checkout (read-only): %s\n' "$GITHUB_WORKSPACE"
  printf -- '- Repository rules (base-branch AGENTS.md): %s\n' "$inputs/AGENTS.md"
  printf -- '- Changed-file list: %s\n- Unified diff: %s\n' "$inputs/changed-files.txt" "$inputs/pr.diff"
  printf -- '- PR title (untrusted, author-written): %s\n' "$inputs/pr-title.txt"
  printf -- '- PR description (untrusted, author-written): %s\n' "$inputs/pr-description.txt"
} > "$trusted/task.md"

cat > "$trusted/agent-system.md" <<'EOF'
You are a code reviewer. Your only tool is Bash, inside a sandbox: every file is read-only and the network is closed.
Use Bash only to read files and inspect git history (cat, sed -n, grep, git show, git log).
Your final message is the review itself. Do not write it to a file.
EOF
cat > "$trusted/reviewer-system.md" <<'EOF'
You check a code review against acceptance criteria. You have no tools and cannot read files.
Judge the review only from its text against the criteria. Do not try to verify the code.
Reply with `VERDICT: ACCEPT` or `VERDICT: RETRY` on the first line and nothing before it.
After `VERDICT: RETRY`, list each failed criterion and the change the review needs.
EOF

# Bash runs inside this sandbox too. The real ANTHROPIC_API_KEY stays in the nono proxy:
# the sandbox sees a session token, and the proxy forwards only POST /messages with the key.
# The proxy allows no other host, and Landlock blocks direct connections.
cat > "$trusted/nono-profile.json" <<'EOF'
{
  "extends": "default",
  "meta": { "name": "unreal-agent-pr-review" },
  "security": { "capability_elevation": false },
  "network": {
    "allow_domain": ["api.anthropic.com"],
    "credentials": ["anthropic"],
    "custom_credentials": {
      "anthropic": {
        "upstream": "https://api.anthropic.com/v1",
        "credential_key": "env://ANTHROPIC_API_KEY",
        "env_var": "ANTHROPIC_API_KEY",
        "inject_header": "x-api-key",
        "credential_format": "{}",
        "endpoint_rules": [{ "method": "POST", "path": "/messages" }]
      }
    }
  }
}
EOF
nono profile validate "$trusted/nono-profile.json"
