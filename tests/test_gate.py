"""Runs scripts/gate.sh the way the gate step runs it, with a temporary GITHUB_OUTPUT."""

import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def run_gate(tmp_path: Path, **env: str) -> tuple[subprocess.CompletedProcess, list[str]]:
    output = tmp_path / "github-output"
    output.touch()
    step_env = {
        "PATH": os.environ["PATH"],
        # gate.sh needs a Linux runner. Bash keeps an OSTYPE it inherits, so the test runs anywhere.
        "OSTYPE": "linux-gnu",
        "GITHUB_OUTPUT": str(output),
        "GITHUB_ACTION_PATH": str(ROOT),
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REPOSITORY": "owner/repo",
        "HEAD_REPO": "owner/repo",
        "PR_DRAFT": "false",
        "PR_AUTHOR": "developer",
        "SKIP_RENOVATE": "true",
        "PROVIDER": "anthropic",
        "MODEL": "",
        "LLM_API_KEY": "test-key",
        "MAX_REVIEW_ROUNDS": "3",
        "REVIEW_TIMEOUT_MINUTES": "40",
        "REVIEW_MODE": "standard",
        "USE_DEFAULT_PROMPTS": "false",
        "SKIP_REASON": "",
        "WAITING_FOR": "",
    } | env
    result = subprocess.run(
        ["bash", str(ROOT / "scripts" / "gate.sh")],
        env=step_env,
        capture_output=True,
        text=True,
        check=False,
    )
    return result, output.read_text().splitlines()


def mode_outputs(lines: list[str]) -> dict[str, str]:
    """The three mode outputs, each of which gate.sh must write exactly once."""
    found = {}
    for key in ("prompt-dir", "suffix", "title"):
        values = [line.split("=", 1)[1] for line in lines if line.startswith(f"{key}=")]
        assert len(values) == 1, f"{key} written {len(values)} times: {lines}"
        found[key] = values[0]
    return found


@pytest.mark.parametrize(
    ("mode", "expected"),
    [
        ("standard", {"prompt-dir": "", "suffix": "", "title": "Unreal Agent review"}),
        (
            "adversarial",
            {
                "prompt-dir": "adversarial/",
                "suffix": "-adversarial",
                "title": "Unreal Agent adversarial review",
            },
        ),
        (
            "security",
            {
                "prompt-dir": "security/",
                "suffix": "-security",
                "title": "Unreal Agent security review",
            },
        ),
    ],
)
def test_each_mode_sets_its_prompt_directory_marker_suffix_and_title(tmp_path, mode, expected):
    result, lines = run_gate(tmp_path, REVIEW_MODE=mode)

    assert result.returncode == 0, result.stdout + result.stderr
    assert mode_outputs(lines) == expected
    assert "skipped=false" in lines


def test_security_mode_writes_the_suffix_key_that_action_yml_reads(tmp_path):
    # action.yml reads steps.gate.outputs.suffix; a marker-suffix key would leave it empty and
    # make the security comment overwrite the standard one.
    _, lines = run_gate(tmp_path, REVIEW_MODE="security")

    assert "suffix=-security" in lines
    assert not any(line.startswith("marker-suffix=") for line in lines)


@pytest.mark.parametrize("mode", ["bogus", "", "Security", "security "])
def test_unknown_mode_fails_before_any_mode_output(tmp_path, mode):
    result, lines = run_gate(tmp_path, REVIEW_MODE=mode)

    assert result.returncode == 1
    assert (
        f"::error::review-mode must be standard, adversarial, or security, got '{mode}'."
        in result.stdout
    )
    assert not any(line.startswith(("prompt-dir=", "suffix=", "title=")) for line in lines)


@pytest.mark.parametrize("value", ["true", "false"])
def test_use_default_prompts_accepts_true_and_false(tmp_path, value):
    result, _ = run_gate(tmp_path, REVIEW_MODE="security", USE_DEFAULT_PROMPTS=value)

    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("value", ["TRUE", "yes", "1", ""])
def test_use_default_prompts_rejects_any_other_value(tmp_path, value):
    # prepare.sh pins only on the exact string "true"; a typo must fail here, not silently
    # read the prompt from the base branch.
    result, lines = run_gate(tmp_path, REVIEW_MODE="security", USE_DEFAULT_PROMPTS=value)

    assert result.returncode == 1
    assert f"::error::use-default-prompts must be true or false, got '{value}'." in result.stdout
    assert "skipped=false" not in lines
