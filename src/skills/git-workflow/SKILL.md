---
name: git-workflow
description: Safe Git operations. Commit, branch, merge, rebase with best practices. Never force push to main.
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Git, Version Control, PR, Branching, Merge]
    category: development
---

# Git Workflow

Safe and effective Git version control.

## When to Use
- Committing changes, creating branches, merging
- Preparing PRs or releases
- Resolving merge conflicts
- Repository maintenance

## Process
1. Check current state: git status, git log --oneline -5
2. Plan the operation and verify safety
3. Execute with appropriate flags
4. Verify result with git status or git log

## Safety Rules
- Never force push to main/master without explicit permission
- Always check git status before committing
- Create new commits rather than amending published commits
- Never skip hooks (--no-verify, --no-gpg-sign) unless explicitly asked
- If a hook fails, fix the issue and create a NEW commit
- Use conventional commits: fix:, feat:, refactor:, docs:, test:
- Confirm with user before destructive operations (reset --hard, push --force)
