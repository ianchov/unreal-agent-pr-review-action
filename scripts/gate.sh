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

# Settings for each model provider. The nono proxy forwards only POST <path> to <upstream> and adds
# the key in <header>. Unreal Agent's Anthropic client calls /messages; its OpenAI and OpenRouter
# clients call /responses. OpenAI has no default model.
case "$PROVIDER" in
  anthropic) key_input=anthropic-api-key default_model=claude-sonnet-5-5 domain=api.anthropic.com
    upstream=https://api.anthropic.com/v1 header=x-api-key format='{}' path=/messages ;;
  openai) key_input=openai-api-key default_model="" domain=api.openai.com
    upstream=https://api.openai.com/v1 header=Authorization format='Bearer {}' path=/responses ;;
  openrouter) key_input=openrouter-api-key default_model=openai/gpt-6-sol domain=openrouter.ai
    upstream=https://openrouter.ai/api/v1 header=Authorization format='Bearer {}' path=/responses ;;
  *) echo "::error::provider must be anthropic, openai, or openrouter, got '$PROVIDER'."; exit 1 ;;
esac
[ -n "$LLM_API_KEY" ] || { echo "::error::Input $key_input is empty. Set it for provider $PROVIDER."; exit 1; }
model="${MODEL:-$default_model}"
[ -n "$model" ] || { echo "::error::Input model is required for provider $PROVIDER."; exit 1; }
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
{
  echo "model=$model"
  echo "llm-domain=$domain"
  echo "llm-upstream=$upstream"
  echo "llm-header=$header"
  echo "llm-format=$format"
  echo "llm-path=$path"
} >> "$GITHUB_OUTPUT"
echo "skipped=false" >> "$GITHUB_OUTPUT"
