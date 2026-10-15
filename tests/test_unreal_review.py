import json

import pytest
import unreal_review as ur

PRICES = {
    "_source": "test",
    "claude-sonnet-5-5": [
        {"input": 2, "cache_write_5m": 2.5, "cache_write_1h": 4, "cache_read": 0.1, "output": 10}
    ],
    "claude-haiku-5-5": [
        {
            "max_prompt_tokens": 100000,
            "input": 0.1,
            "cache_write_5m": 0.125,
            "cache_write_1h": 0.2,
            "cache_read": 0.01,
            "output": 0.5,
        },
        {
            "input": 0.5,
            "cache_write_5m": 0.625,
            "cache_write_1h": 1,
            "cache_read": 0.05,
            "output": 2.5,
        },
    ],
}


def anthropic_usage(uncached=0, write_5m=0, write_1h=0, read=0, output=0, geo="global") -> dict:
    """A usage record shaped like the runner's Anthropic responses."""
    return {
        "InputTokens": uncached + write_5m + write_1h + read,
        "CachedInputTokens": read,
        "CacheWriteInputTokens": write_5m + write_1h,
        "OutputTokens": output,
        "Raw": {
            "input_tokens": uncached,
            "cache_creation_input_tokens": write_5m + write_1h,
            "cache_creation": {
                "ephemeral_5m_input_tokens": write_5m,
                "ephemeral_1h_input_tokens": write_1h,
            },
            "cache_read_input_tokens": read,
            "output_tokens": output,
            "inference_geo": geo,
        },
    }


def openrouter_usage(cost, upstream=None, byok=False) -> dict:
    raw = {"input_tokens": 10, "output_tokens": 5, "cost": cost, "is_byok": byok}
    if upstream is not None:
        raw["cost_details"] = {"upstream_inference_cost": upstream}
    return {"InputTokens": 10, "CachedInputTokens": 0, "CacheWriteInputTokens": 0,
            "OutputTokens": 5, "Raw": raw}  # fmt: skip


def event(usage: dict) -> str:
    return json.dumps({"Kind": "model_response", "Data": {"Response": {"Usage": usage}}})


# Provider settings


def test_anthropic_defaults_to_sonnet_and_messages_endpoint():
    settings = ur.provider_settings("anthropic", "", "key")

    assert settings["model"] == "claude-sonnet-5-5"
    assert settings["llm-path"] == "/messages"
    assert settings["llm-header"] == "x-api-key"
    assert settings["llm-format"] == "{}"


def test_openrouter_defaults_to_gpt_6_sol_with_bearer_auth():
    settings = ur.provider_settings("openrouter", "", "key")

    assert settings["model"] == "openai/gpt-6-sol"
    assert settings["llm-upstream"] == "https://openrouter.ai/api/v1"
    assert settings["llm-format"] == "Bearer {}"


def test_given_model_overrides_the_default():
    assert ur.provider_settings("anthropic", "claude-opus-5-5", "key")["model"] == "claude-opus-5-5"


def test_openai_needs_a_model():
    with pytest.raises(ur.InputError, match="model is required for provider openai"):
        ur.provider_settings("openai", "", "key")


def test_missing_key_names_the_input_to_set():
    with pytest.raises(ur.InputError, match="openrouter-api-key is empty"):
        ur.provider_settings("openrouter", "", "")


def test_unknown_provider_is_rejected():
    with pytest.raises(ur.InputError, match="provider must be anthropic, openai, or openrouter"):
        ur.provider_settings("gemini", "x", "key")


# Review verdict


@pytest.mark.parametrize(
    ("text", "verdict"),
    [
        ("## Verdict\nReady to merge\n", "Ready to merge"),
        ("## Verdict\n\n**Merge after fixes.**\n", "Merge after fixes"),
        ("## Verdict\n`Needs rework`\n", "Needs rework"),
        (
            "## Summary\nx\n## Findings\nNo findings.\n## Verdict\n  Ready to merge.  \n",
            "Ready to merge",
        ),
    ],
)
def test_verdict_line_is_read_with_formatting_removed(text, verdict):
    assert ur.review_verdict(text) == verdict


@pytest.mark.parametrize(
    "text",
    [
        "## Summary\nNo verdict section.\n",
        "## Verdict\nShip it\n",
        "## Verdict\n\n",
        # Only the first non-empty line counts; a later valid line does not rescue it.
        "## Verdict\nProbably fine\nReady to merge\n",
    ],
)
def test_missing_or_unknown_verdict_is_empty(text):
    assert ur.review_verdict(text) == ""


# Highest finding severity


FINDINGS = (
    "## Summary\nMentions a **[P0]** risk in prose only.\n\n"
    "## Findings\n\n"
    "1. **[P3]** a.py:1 — minor\n"
    "2. **[P2]** b.py:2 — edge case\n"
    "   Quotes `**[P1]**` inside a paragraph, not as a finding tag.\n"
    "3. **[P3]** c.py:3 — minor\n\n"
    "## Verdict\nMerge after fixes\n"
)


def test_highest_severity_is_the_most_severe_finding_tag():
    assert ur.review_severity(FINDINGS) == "P2"


def test_severity_ignores_tags_outside_the_findings_section_and_inside_paragraphs():
    # The P0 in the summary and the quoted P1 in a paragraph do not count.
    assert ur.review_severity(FINDINGS) not in ("P0", "P1")


@pytest.mark.parametrize(
    ("findings", "severity"),
    [
        ("1. **[P1]** x.py:1 — wrong\n2. **[P0]** y.py:2 — data loss\n", "P0"),
        ("1. **[P1]** x.py:1 — wrong\n", "P1"),
        ("  10. **[P3]** x.py:1 — tenth item, indented\n", "P3"),
    ],
)
def test_highest_severity_wins_wherever_it_is_listed(findings, severity):
    review = f"## Summary\ns\n\n## Findings\n{findings}\n## Verdict\nNeeds rework\n"
    assert ur.review_severity(review) == severity


def test_no_findings_is_none():
    review = "## Summary\ns\n\n## Findings\nNo findings.\n\n## Verdict\nReady to merge\n"
    assert ur.review_severity(review) == "none"


def test_review_without_findings_section_has_no_severity():
    assert ur.review_severity("Unreal Agent returned something else.\n") == ""


# Reviewer check verdict


def test_reviewer_verdict_is_the_last_line_after_its_reasons():
    reply = (
        "VERDICT: RETRY\n- criterion 5 fails\nOn reflection none fail.\n\n**VERDICT: ACCEPT**\n\n"
    )
    assert ur.reviewer_verdict(reply) == "ACCEPT"


@pytest.mark.parametrize(
    ("reply", "verdict"),
    [
        ("- Criterion 4: missing note.\n`VERDICT: RETRY`\r\n", "RETRY"),
        ("Every criterion holds.\nVERDICT:ACCEPT\n", "ACCEPT"),
        ("Looks fine.\n", ""),
        ("", ""),
    ],
)
def test_reviewer_verdict_needs_a_verdict_on_the_last_line(reply, verdict):
    assert ur.reviewer_verdict(reply) == verdict


# Cost


def test_anthropic_cost_prices_each_token_kind_from_the_list():
    usage = anthropic_usage(uncached=64, write_5m=107613, read=1932257, output=19308)

    # The smspanel run 38661692170 standard job, checked by hand: $0.6555.
    assert ur.call_cost(usage, "claude-sonnet-5-5", PRICES) == pytest.approx(0.655466, abs=1e-6)


def test_one_hour_cache_writes_cost_more_than_five_minute_ones():
    five = ur.call_cost(anthropic_usage(write_5m=1_000_000), "claude-sonnet-5-5", PRICES)
    hour = ur.call_cost(anthropic_usage(write_1h=1_000_000), "claude-sonnet-5-5", PRICES)

    assert (five, hour) == (pytest.approx(2.5), pytest.approx(4.0))


def test_haiku_prompts_over_100k_tokens_use_the_higher_row():
    small = ur.call_cost(anthropic_usage(uncached=100_000), "claude-haiku-5-5", PRICES)
    large = ur.call_cost(anthropic_usage(uncached=100_001), "claude-haiku-5-5", PRICES)

    assert small == pytest.approx(0.01)
    assert large == pytest.approx(100_001 * 0.5 / 1e6)


def test_us_only_inference_costs_ten_percent_more():
    usage = anthropic_usage(uncached=1_000_000, geo="us")

    assert ur.call_cost(usage, "claude-sonnet-5-5", PRICES) == pytest.approx(2.2)


def test_openrouter_byok_cost_adds_the_provider_charge():
    usage = openrouter_usage(cost=0.0, upstream=0.004696, byok=True)

    assert ur.call_cost(usage, "openai/gpt-6-sol", PRICES) == pytest.approx(0.004696)


def test_openrouter_without_byok_counts_only_its_own_charge():
    usage = openrouter_usage(cost=0.02, upstream=0.019, byok=False)

    assert ur.call_cost(usage, "openai/gpt-6-sol", PRICES) == pytest.approx(0.02)


def test_model_without_price_has_no_cost():
    assert ur.call_cost(anthropic_usage(uncached=10), "gpt-5", PRICES) is None


# Usage line


def test_usage_line_sums_tokens_and_cost_of_every_call():
    lines = [event(anthropic_usage(uncached=100, read=900, output=50)) for _ in range(3)]

    line = ur.usage_line(lines, "claude-sonnet-5-5", PRICES)

    assert line == (
        "Tokens: 3 model calls, 3000 input (2700 cache read, 0 cache write), 150 output."
        " Cost: $0.0024 (estimate from Anthropic list prices)."
    )


def test_cost_that_the_responses_report_is_labelled_as_reported_by_openrouter():
    line = ur.usage_line([event(openrouter_usage(0.0123))], "claude-sonnet-5-5", PRICES)

    assert line.endswith(" Cost: $0.0123 (reported by OpenRouter).")


def test_one_unpriced_call_drops_the_cost_instead_of_undercounting():
    lines = [event(openrouter_usage(0.01)), event(anthropic_usage(uncached=10))]

    line = ur.usage_line(lines, "openai/gpt-6-sol", PRICES)

    assert "Cost" not in line
    assert line.startswith("Tokens: 2 model calls")


def test_cut_off_and_other_events_are_skipped():
    lines = [
        event(anthropic_usage(uncached=1, output=1)),
        '{"Kind": "model_response", "Data": {"Resp',
        json.dumps({"Kind": "input", "Data": {}}),
        "",
    ]

    line = ur.usage_line(lines, "claude-sonnet-5-5", PRICES)

    assert line.startswith("Tokens: 1 model calls, 1 input")


def test_no_calls_gives_zero_tokens_and_no_cost():
    assert ur.usage_line([], "claude-sonnet-5-5", PRICES) == (
        "Tokens: 0 model calls, 0 input (0 cache read, 0 cache write), 0 output."
    )


# Outdated comment


TITLE = "Unreal Agent adversarial review"
REVIEW = (
    "_Passed the reviewer check._\n"
    "\n"
    "## Findings\n"
    "1. **[P2]** a.py:1 — quoted text: > **Reviewing commit 1234567.** stays\n"
    "\n"
    "<sub>Tokens: 3 model calls.</sub>\n"
)
POSTED = (
    "<!-- unreal-agent-pr-review-adversarial -->\n"
    "### Unreal Agent adversarial review (`claude-sonnet-5-5`, commit c15fbcb)\n"
    "\n" + REVIEW
)


def previous_review(comment: str) -> str:
    """The collapsed part of an outdated comment, without its opening and closing tags."""
    start = comment.index("<details><summary>")
    return comment[start:].split("\n", 1)[1].rsplit("</details>", 1)[0]


def test_running_review_names_the_new_commit_and_collapses_the_old_review():
    comment = ur.outdated_comment(POSTED, TITLE, "c7ff0e1aa", "")

    lines = comment.splitlines()
    assert lines[0] == "<!-- unreal-agent-pr-review-adversarial -->"
    assert lines[1] == "### Unreal Agent adversarial review: reviewing commit c7ff0e1"
    assert "_In progress. The review of c7ff0e1 replaces this comment when it finishes._" in lines
    assert "<details><summary>Previous review: claude-sonnet-5-5, commit c15fbcb</summary>" in lines
    assert previous_review(comment).strip() == REVIEW.strip()


def test_skipped_review_says_why_above_the_old_review():
    comment = ur.outdated_comment(
        POSTED, TITLE, "c7ff0e1aa", "the standard review found a P1 defect"
    )

    lines = comment.splitlines()
    assert lines[1] == "### Unreal Agent adversarial review: not run for commit c7ff0e1"
    assert "_Not reviewed: the standard review found a P1 defect._" in lines
    assert previous_review(comment).strip() == REVIEW.strip()


def test_waiting_review_names_the_new_commit_and_what_it_waits_for():
    comment = ur.outdated_comment(POSTED, TITLE, "c7ff0e1aa", "", "the standard review")

    lines = comment.splitlines()
    assert lines[1] == "### Unreal Agent adversarial review: waiting for commit c7ff0e1"
    assert "_Waiting for the standard review of commit c7ff0e1._" in lines
    assert previous_review(comment).strip() == REVIEW.strip()


def test_skip_reason_wins_over_waiting():
    comment = ur.outdated_comment(POSTED, TITLE, "c7ff0e1aa", "a reason", "the standard review")

    assert comment.splitlines()[1].endswith("not run for commit c7ff0e1")


def test_waiting_then_reviewing_keeps_one_collapsed_review():
    comment = ur.outdated_comment(POSTED, TITLE, "1" * 8, "", "the standard review")
    comment = ur.outdated_comment(comment, TITLE, "1" * 8, "")

    assert comment.count("<details>") == 1
    assert comment.splitlines()[1].endswith("reviewing commit 1111111")
    assert previous_review(comment).strip() == REVIEW.strip()


def test_markdown_inside_the_collapsed_review_renders():
    # GitHub renders Markdown inside <details> only after a blank line.
    comment = ur.outdated_comment(POSTED, TITLE, "c7ff0e1aa", "")

    after_summary = comment.split("</summary>\n", 1)[1]
    assert after_summary.startswith("\n")
    assert comment.endswith("\n</details>\n")


def test_later_runs_keep_one_collapsed_review_of_the_last_finished_one():
    comment = POSTED
    for sha, reason in [("1" * 8, ""), ("2" * 8, "reason"), ("3" * 8, "")]:
        comment = ur.outdated_comment(comment, TITLE, sha, reason)

    assert comment.count("<details>") == 1
    assert "Previous review: claude-sonnet-5-5, commit c15fbcb" in comment
    assert comment.splitlines()[1].endswith("reviewing commit 3333333")
    assert previous_review(comment).strip() == REVIEW.strip()


@pytest.mark.parametrize(
    "note",
    [
        "> **Reviewing commit 9999999.** The review below is for the older commit in the title.",
        "> **Not reviewed for commit 9999999:** reason. The review below is for the older commit.",
    ],
)
def test_one_line_note_of_older_versions_is_dropped(note):
    old_style = POSTED.replace("\n\n_Passed", f"\n{note}\n\n_Passed", 1)

    comment = ur.outdated_comment(old_style, TITLE, "c7ff0e1aa", "")

    assert "9999999" not in comment
    assert previous_review(comment).strip() == REVIEW.strip()


def test_comment_without_a_review_title_is_still_collapsed():
    body = "<!-- unreal-agent-pr-review -->\nSomething else.\n"

    comment = ur.outdated_comment(body, "Unreal Agent review", "c7ff0e1aa", "")

    assert comment.startswith("<!-- unreal-agent-pr-review -->\n### Unreal Agent review: reviewing")
    assert "<details><summary>Previous review</summary>" in comment
    assert previous_review(comment).strip() == "Something else."
