#!/usr/bin/env bash
# Posts the review as one PR comment per review mode and updates that comment on later runs.
# With the argument "pending", it only rewrites an existing comment for a newer commit: the title
# names that commit and says it is being reviewed, or (SKIP_NOTE set) not reviewed and why. The last
# finished review stays below it, collapsed. The next posted review replaces the whole comment.
set -euo pipefail

trusted="$RUNNER_TEMP/unreal-agent"
mkdir -p "$trusted"
# MARKER_SUFFIX (from gate.sh) gives each review mode its own comment.
marker="<!-- unreal-agent-pr-review${MARKER_SUFFIX} -->"
comment_id=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$marker\"))) | .id" | head -n 1)

if [ "${1:-}" = pending ]; then
  [ -n "$comment_id" ] || exit 0
  gh api "repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" --jq .body \
    | python3 "$GITHUB_ACTION_PATH/scripts/unreal_review.py" outdated "$TITLE" "$HEAD_SHA" "${SKIP_NOTE:-}" \
    > "$trusted/pending-comment.md"
  gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" -F body=@"$trusted/pending-comment.md" > /dev/null
  exit 0
fi

{
  echo "$marker"
  echo "### ${TITLE} (\`${MODEL}\`, commit ${HEAD_SHA:0:7})"
  echo
  echo "_$(cat "$trusted/review-status.txt")_"
  echo
  cat "$trusted/review.md"
  echo
  echo "<sub>$(cat "$trusted/usage.txt")</sub>"
} > "$trusted/comment.md"
if [ -n "$comment_id" ]; then
  gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" -F body=@"$trusted/comment.md" > /dev/null
else
  gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" -F body=@"$trusted/comment.md" > /dev/null
fi
