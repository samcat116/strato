---
name: PR Review Watch
description: Watch for and address Codex review comments on PRs
---
The goal is to address all review comments on Github PRs from the Codex Review bot. Codex Review Bot is currently reviewing when it reacts to the PR description with an eyes emoji. When its done reviewing, it will post a comment with any review findings. You should review, address, and commit these findings to the PR branch and push them to Github. This will trigger a new review from Codex. You should wait for the Codex bot to process that there were new pushes to the branch. The Codex review bot will repeat this until it reacts with a thumbs up emoji to the PR description, signifying there are no more comments and that the PR is good to merge. You should then also fix/address any CI failures or merge conflicts with the PR, before letting me know that the PR is good to merge.
