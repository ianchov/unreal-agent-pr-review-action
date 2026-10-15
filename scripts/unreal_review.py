"""Review logic that the action's shell scripts call: provider settings, verdicts, usage and cost,
and the note on an outdated comment. The shell scripts keep the git, gh, and nono calls.

Runs with the runner's python3 and the standard library only, so the action installs nothing.
Usage: python3 unreal_review.py <command> [args]; see main().
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

PRICES_PATH = Path(__file__).with_name("anthropic-prices.json")
REVIEW_VERDICTS = ("Ready to merge", "Merge after fixes", "Needs rework")
PREVIOUS_SUMMARY = "<details><summary>Previous review"
# The one-line note that versions before v1.8.0 put under the title of an outdated comment.
OLD_NOTE_PREFIXES = ("> **Reviewing commit ", "> **Not reviewed for commit ")


class InputError(Exception):
    """An action input is invalid; the message is shown as the step's error."""


@dataclass(frozen=True)
class Provider:
    """How the nono proxy reaches one model API. It forwards only POST <path> to <upstream>."""

    key_input: str
    default_model: str
    domain: str
    upstream: str
    header: str
    credential_format: str
    path: str


# Unreal Agent's Anthropic client calls /messages; its OpenAI and OpenRouter clients call
# /responses.
PROVIDERS = {
    "anthropic": Provider(
        "anthropic-api-key", "claude-sonnet-5-5", "api.anthropic.com",
        "https://api.anthropic.com/v1", "x-api-key", "{}", "/messages",
    ),
    "openai": Provider(
        "openai-api-key", "", "api.openai.com",
        "https://api.openai.com/v1", "Authorization", "Bearer {}", "/responses",
    ),
    "openrouter": Provider(
        "openrouter-api-key", "openai/gpt-6-sol", "openrouter.ai",
        "https://openrouter.ai/api/v1", "Authorization", "Bearer {}", "/responses",
    ),
}  # fmt: skip


def provider_settings(provider: str, model: str, api_key: str) -> dict[str, str]:
    """Return the step outputs for a provider, or raise InputError for a bad input."""
    settings = PROVIDERS.get(provider)
    if settings is None:
        raise InputError(f"provider must be anthropic, openai, or openrouter, got '{provider}'.")
    if not api_key:
        raise InputError(f"Input {settings.key_input} is empty. Set it for provider {provider}.")
    model = model or settings.default_model
    if not model:
        raise InputError(f"Input model is required for provider {provider}.")
    return {
        "model": model,
        "llm-domain": settings.domain,
        "llm-upstream": settings.upstream,
        "llm-header": settings.header,
        "llm-format": settings.credential_format,
        "llm-path": settings.path,
    }


def _plain(line: str) -> str:
    """A line without Markdown emphasis or code marks, surrounding space, and a trailing period."""
    return re.sub(r"[*`]", "", line).strip().rstrip(".").strip()


def review_verdict(review: str) -> str:
    """The first non-empty line under '## Verdict' if it is a known verdict, else ''."""
    lines = review.splitlines()
    if "## Verdict" not in (line.strip() for line in lines):
        return ""
    after = lines[[line.strip() for line in lines].index("## Verdict") + 1 :]
    first = next((line for line in after if line.strip()), "")
    verdict = _plain(first)
    return verdict if verdict in REVIEW_VERDICTS else ""


def review_severity(review: str) -> str:
    """The most severe finding tag ('P0' to 'P3') in the '## Findings' section.

    'none' when the section has no tagged finding, '' when the review has no such section.
    Only list items that start with a tag count, not tags quoted in prose or other sections.
    """
    lines = review.splitlines()
    starts = [i for i, line in enumerate(lines) if line.strip() == "## Findings"]
    if not starts:
        return ""
    tags = []
    for line in lines[starts[0] + 1 :]:
        if line.startswith("## "):
            break
        match = re.match(r"\s*\d+\.\s+\*\*\[P([0-3])\]\*\*", line)
        if match:
            tags.append(int(match.group(1)))
    return f"P{min(tags)}" if tags else "none"


def reviewer_verdict(reply: str) -> str:
    """'ACCEPT' or 'RETRY' from the reviewer check's last non-empty line, else ''.

    The reviewer gives its reasons first and decides last, so an early verdict line it later
    corrects does not count.
    """
    last = next((line for line in reversed(reply.splitlines()) if line.strip()), "")
    match = re.fullmatch(r"VERDICT:(ACCEPT|RETRY)", re.sub(r"[\s*`]", "", last))
    return match.group(1) if match else ""


def call_cost(usage: dict, model: str, prices: dict) -> float | None:
    """USD cost of one model call, or None when it cannot be priced.

    OpenRouter reports its charge in the response; with a BYOK key the provider's charge to that key
    comes on top. Anthropic calls are priced from the list prices (USD per million tokens).
    """
    raw = usage.get("Raw") or {}
    if raw.get("cost") is not None:
        upstream = (raw.get("cost_details") or {}).get("upstream_inference_cost") or 0
        return raw["cost"] + (upstream if raw.get("is_byok") else 0)
    if raw.get("input_tokens") is None:
        return None
    writes = raw.get("cache_creation") or {}
    write_1h = writes.get("ephemeral_1h_input_tokens") or 0
    write_5m = writes.get(
        "ephemeral_5m_input_tokens", (raw.get("cache_creation_input_tokens") or 0) - write_1h
    )
    read = raw.get("cache_read_input_tokens") or 0
    prompt = raw["input_tokens"] + write_5m + write_1h + read
    rows = [
        row
        for row in prices.get(model, [])
        if row.get("max_prompt_tokens") is None or prompt <= row["max_prompt_tokens"]
    ]
    if not rows:
        return None
    row = rows[0]
    cost = (
        raw["input_tokens"] * row["input"]
        + write_5m * row["cache_write_5m"]
        + write_1h * row["cache_write_1h"]
        + read * row["cache_read"]
        + (raw.get("output_tokens") or 0) * row["output"]
    ) / 1_000_000
    return cost if raw.get("inference_geo", "global") == "global" else cost * 1.1


def _usages(event_lines: Iterable[str]) -> list[dict]:
    """Usage of every model call. A line cut off by a killed runner is skipped, not fatal."""
    usages = []
    for line in event_lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and event.get("Kind") == "model_response":
            usages.append(((event.get("Data") or {}).get("Response") or {}).get("Usage") or {})
    return usages


def usage_line(event_lines: Iterable[str], model: str, prices: dict) -> str:
    """Token totals of all agent and reviewer calls, and their cost when every call can be priced.

    Input includes cache reads and writes. The cost is labelled by where it came from: the
    responses (OpenRouter) or the Anthropic list prices.
    """
    usages = _usages(event_lines)
    total = {
        key: sum(u.get(key) or 0 for u in usages)
        for key in ("InputTokens", "CachedInputTokens", "CacheWriteInputTokens", "OutputTokens")
    }
    line = (
        f"Tokens: {len(usages)} model calls, {total['InputTokens']} input"
        f" ({total['CachedInputTokens']} cache read, {total['CacheWriteInputTokens']} cache write),"
        f" {total['OutputTokens']} output."
    )
    costs = [call_cost(u, model, prices) for u in usages]
    if not costs or None in costs:
        return line
    reported = all((u.get("Raw") or {}).get("cost") is not None for u in usages)
    source = "reported by OpenRouter" if reported else "estimate from Anthropic list prices"
    return f"{line} Cost: ${sum(costs):.4f} ({source})."


def outdated_comment(body: str, title: str, head_sha: str, skip_note: str) -> str:
    """A posted review comment, rewritten for a newer commit that is being reviewed or skipped.

    The title and status name the new commit. The last finished review stays below, collapsed in
    one <details> block that names its model and commit. A comment that is already outdated keeps
    that block, so later runs never nest or lose it. The next posted review replaces all of this.
    """
    marker, _, rest = body.partition("\n")
    commit = head_sha[:7]
    if skip_note:
        heading = f"### {title}: not run for commit {commit}"
        status = f"_Not reviewed: {skip_note}._"
    else:
        heading = f"### {title}: reviewing commit {commit}"
        status = f"_In progress. The review of {commit} replaces this comment when it finishes._"

    start = rest.find(PREVIOUS_SUMMARY)
    if start >= 0:
        previous = rest[start:].rstrip("\n")
    else:
        lines = rest.splitlines()
        summary = "Previous review"
        if lines and lines[0].startswith("### "):
            match = re.search(r"\(([^()]*)\)\s*$", lines.pop(0))
            if match:
                summary += ": " + match.group(1).replace("`", "")
        content = "\n".join(line for line in lines if not line.startswith(OLD_NOTE_PREFIXES))
        previous = f"<details><summary>{summary}</summary>\n\n{content.strip()}\n\n</details>"
    return f"{marker}\n{heading}\n\n{status}\n\n{previous}\n"


def main(argv: list[str]) -> int:
    command, args = (argv[0], argv[1:]) if argv else ("", [])
    try:
        if command == "provider":
            settings = provider_settings(
                os.environ["PROVIDER"],
                os.environ.get("MODEL", ""),
                os.environ.get("LLM_API_KEY", ""),
            )
            print("\n".join(f"{key}={value}" for key, value in settings.items()))
        elif command == "verdict":
            print(review_verdict(Path(args[0]).read_text()))
        elif command == "severity":
            print(review_severity(Path(args[0]).read_text()))
        elif command == "reviewer-verdict":
            print(reviewer_verdict(Path(args[0]).read_text()))
        elif command == "usage":
            model, *files = args
            lines = [line for f in files for line in Path(f).read_text().splitlines()]
            print(usage_line(lines, model, json.loads(PRICES_PATH.read_text())))
        elif command == "outdated":
            title, head_sha, skip_note = args
            sys.stdout.write(outdated_comment(sys.stdin.read(), title, head_sha, skip_note))
        else:
            print(
                f"usage: {Path(__file__).name}"
                " provider|verdict|severity|reviewer-verdict|usage|outdated",
                file=sys.stderr,
            )
            return 2
    except InputError as error:
        print(f"::error::{error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
