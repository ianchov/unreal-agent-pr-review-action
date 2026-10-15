#!/usr/bin/env bash
# Each round runs the agent in one persisted session, then a second runner call with no tools
# checks the review against review-criteria.md. A failed check sends the reviewer's feedback
# back into the agent's session for another pass, up to MAX_REVIEW_ROUNDS.
# Progress streams to the step log. The full JSONL event logs go to the artifact.
set -euo pipefail

work="$RUNNER_TEMP/unreal-agent-work"
inputs="$RUNNER_TEMP/unreal-agent-inputs"
state="$RUNNER_TEMP/unreal-agent-state"
trusted="$RUNNER_TEMP/unreal-agent"
bin="$RUNNER_TEMP/unreal-agent-bin"
cd "$work"

# nono sets LLM_BASE_URL (from the "llm" credential in prepare.sh) to its proxy inside the sandbox,
# so it must expand there.
# shellcheck disable=SC2016
run_agent() { # request.json events.jsonl
  nono run --silent --profile "$trusted/nono-profile.json" \
    --read "$bin" --read "$work" --read "$GITHUB_WORKSPACE" --read "$inputs" --allow "$state" \
    -- sh -c 'UNREAL_HARNESS_LLM_BASE_URL="$LLM_BASE_URL" exec "$1" -workspace "$2" -session-directory "$3"' \
    sh "$bin/unreal-agent-runner" "$work" "$state" < "$1" \
    | tee "$2" \
    | jq -r --unbuffered '
        if .type == "error" then "error: \(.message)"
        elif .Kind == "model_response" then
          .Data.Response.Output[]?
          | if .Type == "tool_call" then "$ \(.Data.Arguments | try (fromjson | .command // tojson) catch .)"
            elif .Type == "message" then "message: \(.Data.Text | .[0:300])"
            else empty end
        else empty end'
}
# Events are parsed line by line, so a line cut off by a killed runner is skipped, not fatal.
final_answer() { # events.jsonl: message text of the last model response, the one that ended the run
  jq -Rnr '[inputs | fromjson? | select(.Kind == "model_response")] | last | [.Data.Response.Output[]? | select(.Type == "message") | .Data.Text] | join("\n") | select(test("\\S"))' "$1"
}

session=$(cat /proc/sys/kernel/random/uuid)
jq -n --arg session "$session" --rawfile system "$trusted/agent-system.md" --rawfile prompt "$trusted/task.md" \
  '{session_id: $session, system_prompt: $system, prompt: $prompt, thinking_level: "high"}' > "$trusted/request.json"
status="Not verified: the reviewer check did not run."
for round in $(seq 1 "$MAX_REVIEW_ROUNDS"); do
  echo "::group::Review round $round"
  run_agent "$trusted/request.json" "$trusted/agent-$round.jsonl" || true
  echo "::endgroup::"
  # A failed or empty retry keeps the previous round's review; only round 1 has nothing to keep.
  # A retry only runs after the reviewer check rejected the previous review, so that review failed it.
  final_answer "$trusted/agent-$round.jsonl" > "$trusted/review-new.md" || true
  if [ ! -s "$trusted/review-new.md" ]; then
    [ "$round" -gt 1 ] || { echo "::error::Unreal Agent returned an empty review."; exit 1; }
    status="Did not pass the reviewer check: round $((round - 1)) review was rejected and round $round returned no review."
    break
  fi
  mv "$trusted/review-new.md" "$trusted/review.md"
  jq -n --rawfile system "$trusted/reviewer-system.md" --rawfile criteria "$trusted/review-criteria.md" --rawfile review "$trusted/review.md" \
    '{system_prompt: $system, prompt: "\($criteria)\nReview to check:\n<review>\n\($review)</review>\n",
      thinking_level: "medium", disallowed_tools: ["Bash", "ViewImage"]}' > "$trusted/reviewer-request.json"
  echo "::group::Reviewer check $round"
  run_agent "$trusted/reviewer-request.json" "$trusted/reviewer-$round.jsonl" || true
  echo "::endgroup::"
  final_answer "$trusted/reviewer-$round.jsonl" > "$trusted/verdict.md" || true
  # The verdict is the last non-empty line, so the reviewer decides after it has checked every criterion.
  case "$(python3 "$GITHUB_ACTION_PATH/scripts/unreal_review.py" reviewer-verdict "$trusted/verdict.md")" in
    ACCEPT) status="Passed the reviewer check."; break ;;
    RETRY) status="Did not pass the reviewer check within ${MAX_REVIEW_ROUNDS} rounds." ;;
    *) status="Not verified: the reviewer check did not return a verdict."; break ;;
  esac
  jq -n --arg session "$session" --rawfile system "$trusted/agent-system.md" --rawfile feedback "$trusted/verdict.md" \
    '{session_id: $session, system_prompt: $system, thinking_level: "high",
      prompt: "Your review did not pass the acceptance check. Fix it and reply with the full corrected review only.\n\n\($feedback)"}' > "$trusted/request.json"
done
[ "$status" = "Passed the reviewer check." ] || echo "::warning::$status"
echo "$status" > "$trusted/review-status.txt"
echo "status=$status" >> "$GITHUB_OUTPUT"
# The verdict line under "## Verdict", for callers that run a second review only after this one,
# for example the adversarial review only after "Ready to merge". Anything else gives an empty verdict.
echo "verdict=$(python3 "$GITHUB_ACTION_PATH/scripts/unreal_review.py" verdict "$trusted/review.md")" >> "$GITHUB_OUTPUT"

# Token totals over every agent and reviewer call, and their cost when every call can be priced:
# OpenRouter reports it, and Anthropic is estimated from anthropic-prices.json.
python3 "$GITHUB_ACTION_PATH/scripts/unreal_review.py" usage \
  "$UNREAL_HARNESS_LLM_MODEL" "$trusted"/*.jsonl > "$trusted/usage.txt"
cat "$trusted/usage.txt"
echo "::group::Final review"
cat "$trusted/review.md"
echo "::endgroup::"
{ cat "$trusted/review.md"; echo; cat "$trusted/usage.txt"; } >> "$GITHUB_STEP_SUMMARY"
