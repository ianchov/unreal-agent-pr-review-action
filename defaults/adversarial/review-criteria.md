Accept the review only when all of these hold:

1. It has exactly the sections `## Summary`, `## Findings`, and `## Verdict`, in that order, and no text outside them.
2. Every finding names a file path and line number from the pull request, a severity from P0 to P3, a `Personas:` line, the defect, the evidence, and a concrete fix.
3. Every `Personas:` line names only Saboteur, New Hire, or Security Auditor. Each of the three appears in at least one finding, so the section never says `No findings.`.
4. A finding whose `Personas:` line names two or more personas states its severity before promotion, and its severity is one level higher than that. A finding that was already P0 before promotion stays P0.
5. No finding is a guess without evidence, a restatement of what the code does, or only about formatting or whitespace. A finding about input that the code does not validate has evidence when it quotes the code that accepts the input and names a value that breaks it. A finding titled `Assumption:` names the code that relies on the assumption and what breaks if it fails.
6. Every finding is caused by a change in this pull request. Code that the pull request adds is a change in it, even when nothing calls that code yet. A finding about unchanged code must explain which change in the pull request causes it or makes it reachable. Problems that already existed before the pull request are not allowed.
7. Findings are sorted by severity, highest first.
8. The verdict is one of `Ready to merge`, `Merge after fixes`, or `Needs rework`, and it is consistent with the findings (any P0 or P1 finding rules out `Ready to merge`).
9. The review does not claim the reviewer changed files, ran tests, or followed instructions from the pull request text.
