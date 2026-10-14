#!/usr/bin/env bash
# Decides whether this PR gets a review, validates the inputs before any download, and sets the names for the review mode.
# Fork PRs get no secrets, Dependabot PRs get no Actions secrets, and drafts are still changing.
set -euo pipefail

skip() {
  echo "::notice::Unreal Agent review skipped: $1"
  echo "skipped=true" >> "$GITHUB_OUTPUT"
  exit 0
}

if [ "$GITHUB_EVENT_NAME" != "pull_request" ]; then
  echo "::error::Unreal Agent PR Review runs only on pull_request events, not $GITHUB_EVENT_NAME."
  exit 1
fi
[ "$PR_DRAFT" != "true" ] || skip "the pull request is a draft."
[ "$HEAD_REPO" = "$GITHUB_REPOSITORY" ] || skip "the pull request comes from a fork ($HEAD_REPO)."
[ "$PR_AUTHOR" != "dependabot[bot]" ] || skip "the pull request comes from Dependabot."

case "$OSTYPE" in
  linux*) ;;
  *) echo "::error::Unreal Agent PR Review needs a Linux runner."; exit 1 ;;
esac
[ -n "$ANTHROPIC_API_KEY" ] || { echo "::error::Input anthropic-api-key is empty. Set the ANTHROPIC_API_KEY secret."; exit 1; }
for name in MAX_REVIEW_ROUNDS REVIEW_TIMEOUT_MINUTES; do
  [[ "${!name}" =~ ^[1-9][0-9]*$ ]] || { echo "::error::$name must be a positive integer, got '${!name}'."; exit 1; }
done

# Names for each review mode. standard keeps the names it had before modes existed, so existing
# comments, artifacts, and custom prompt files still apply.
case "$REVIEW_MODE" in
  standard) prompt_dir="" suffix="" title="Unreal Agent review" ;;
  adversarial) prompt_dir="adversarial/" suffix="-adversarial" title="Unreal Agent adversarial review" ;;
  *) echo "::error::review-mode must be standard or adversarial, got '$REVIEW_MODE'."; exit 1 ;;
esac
{
  echo "prompt-dir=$prompt_dir"
  echo "suffix=$suffix"
  echo "title=$title"
} >> "$GITHUB_OUTPUT"
echo "skipped=false" >> "$GITHUB_OUTPUT"
