---
description: Fetch and address unresolved review comments on this branch's PR
---

Find and address all unresolved review feedback on the current branch's pull request.

1. Find the open PR for the current branch: `gh pr view --json number,title,url`. If there is none, say so and stop.
2. Fetch unresolved review threads via GraphQL:
   ```
   gh api graphql -f query='query { repository(owner: "samcat116", name: "strato") { pullRequest(number: <N>) { reviewThreads(first: 50) { nodes { id isResolved isOutdated path line comments(first: 20) { nodes { databaseId author { login } body } } } } } } }'
   ```
   Also fetch PR-level reviews (`gh pr view --json reviews`) for feedback not attached to a thread.
3. Ignore anything from `chatgpt-codex-connector[bot]` that only reports Codex usage limits — that is noise, take no action on it.
4. For each actionable unresolved comment:
   - Fix the code in this worktree.
   - Commit with a message referencing what the comment asked for.
5. Push once all fixes are committed.
6. Reply on each addressed thread with the fixing commit SHA:
   `gh api repos/samcat116/strato/pulls/<N>/comments/<comment-databaseId>/replies -f body="..."`
7. Resolve each addressed thread:
   `gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "<thread-id>"}) { thread { isResolved } } }'`
8. Summarize: which comments were addressed (with commits), which were skipped and why.

If a comment is wrong or you disagree, reply explaining why instead of silently skipping it, and do not resolve that thread.
