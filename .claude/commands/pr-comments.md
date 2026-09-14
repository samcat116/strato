---
description: Address unresolved feedback on the current branch's pull request.
---

Find the open PR for this branch and address its unresolved review feedback in
this worktree. If there is no open PR, report that and stop.

Fetch review threads through `gh api graphql`, including thread IDs, resolution
state, paths, lines, comment database IDs, authors, and bodies. Follow pagination
for threads and their comments. Include PR-level reviews and discussion comments
so feedback outside inline threads is accounted for. Ignore usage-limit-only
comments from `chatgpt-codex-connector[bot]`.

Apply the relevant sections of [code review](../../docs/development/code-review.md).
Evaluate feedback against the current code, fix actionable findings, and complete
validation for the affected behavior. Group related fixes into coherent commits;
commit messages should identify the feedback they address.

Follow the user's publication scope. When pushing and replying are authorized,
push the fixes and reply to addressed threads with their fixing commit SHAs, then
resolve those threads. Explain disagreements and leave those threads unresolved.
Otherwise, leave the fixes and proposed replies ready for review locally.

Finish with the findings addressed, validation results, commit SHAs, and any
unresolved feedback or publication steps. The command does not merge the PR.
