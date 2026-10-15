#!/usr/bin/env bash
# Decides whether this PR gets a review, validates the inputs before any download, and sets the names
# for the review mode and the settings for the model provider.
# Fork PRs get no secrets, Dependabot PRs get no Actions secrets, and drafts are still changing.
# Renovate PRs are skipped by default: they only bump pinned versions, and their checks gate the merge.
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
[ "$SKIP_RENOVATE" != "true" ] || [ "$PR_AUTHOR" != "renovate[bot]" ] || skip "the pull request comes from Renovate."

case "$OSTYPE" in
  linux*) ;;
  *) echo "::error::Unreal Agent PR Review needs a Linux runner."; exit 1 ;;
esac
[[ "$SKIP_RENOVATE" =~ ^(true|false)$ ]] || { echo "::error::skip-renovate must be true or false, got '$SKIP_RENOVATE'."; exit 1; }

# Provider settings (model, and how the nono proxy reaches the API) live in unreal_review.py.
# It also checks that the provider is known, its key is set, and a model is given or has a default.
if ! provider_settings=$(python3 "$GITHUB_ACTION_PATH/scripts/unreal_review.py" provider); then
  echo "$provider_settings"
  exit 1
fi
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

# A caller-given skip-reason skips the review, for example an adversarial review after a standard
# review that asks for changes. Unlike the skips above, the comment step then marks this mode's old
# comment with the reason, so its review is not read as the review of this commit.
if [ -n "$SKIP_REASON" ]; then
  echo "::notice::Unreal Agent review skipped: $SKIP_REASON"
  { echo "skipped=true"; echo "skip-note=$SKIP_REASON"; } >> "$GITHUB_OUTPUT"
  exit 0
fi
# A caller-given waiting-for only marks this mode's old comment as waiting for another step of this
# commit, for example the adversarial comment while the standard review runs. Nothing is reviewed.
if [ -n "$WAITING_FOR" ]; then
  { echo "skipped=true"; echo "waiting-for=$WAITING_FOR"; } >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "$provider_settings" >> "$GITHUB_OUTPUT"
echo "skipped=false" >> "$GITHUB_OUTPUT"
