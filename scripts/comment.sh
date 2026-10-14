#!/usr/bin/env bash
# Posts the review as one PR comment per review mode and updates that comment on later runs.
set -euo pipefail

trusted="$RUNNER_TEMP/unreal-agent"
# MARKER_SUFFIX (from gate.sh) gives each review mode its own comment.
marker="<!-- unreal-agent-pr-review${MARKER_SUFFIX} -->"
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
comment_id=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$marker\"))) | .id" | head -n 1)
if [ -n "$comment_id" ]; then
  gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" -F body=@"$trusted/comment.md" > /dev/null
else
  gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" -F body=@"$trusted/comment.md" > /dev/null
fi
