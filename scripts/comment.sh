#!/usr/bin/env bash
# Posts the review as one PR comment per review mode and updates that comment on later runs.
# With the argument "pending", it only adds a note to an existing comment that a newer commit is
# being reviewed, so nobody reads an older review as the current one. The final post replaces it.
set -euo pipefail

trusted="$RUNNER_TEMP/unreal-agent"
mkdir -p "$trusted"
# MARKER_SUFFIX (from gate.sh) gives each review mode its own comment.
marker="<!-- unreal-agent-pr-review${MARKER_SUFFIX} -->"
comment_id=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$marker\"))) | .id" | head -n 1)

if [ "${1:-}" = pending ]; then
  [ -n "$comment_id" ] || exit 0
  # Line 3, under the title, holds the note. An earlier run's note is replaced, not stacked.
  note="> **Reviewing commit ${HEAD_SHA:0:7}.** The review below is for the older commit in the title. It updates when this run finishes."
  gh api "repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" --jq .body \
    | awk -v note="$note" 'NR == 3 { print note } NR <= 2 || !/^> \*\*Reviewing commit /' > "$trusted/pending-comment.md"
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
