# Linux administration scripts

Primary branch: `master`.

## Scope and safeguards
- This repository contains standalone administration, backup, maintenance, and quarantine scripts. Follow each script's shebang and documented distribution requirements; preserve LF line endings.
- Keep diffs focused. Update `README.md` when usage, prerequisites, or behavior changes.
- Never execute an administration script merely to test it: updates, deletion, backup pruning, quarantine, mounts, and service changes affect real systems.
- Before destructive actions, verify resolved source/destination paths, expected mounts, retention rules, and backup integrity. Preview `rsync --delete` changes and deletion candidates before applying them. Do not treat an empty or missing source mount as valid input.
- Supply credentials through environment variables or protected local configuration; commit only placeholder examples.

## Verification
- From the repository root, use `bash -n <script.sh>` for Bash scripts and the corresponding interpreter's syntax check for other shells.
- Run `shellcheck <script.sh>` when available; report missing tooling rather than claiming a pass.
- Test behavior with disposable fixtures and mocked external commands. Never use production data as a test fixture.
- Documentation-only changes require path/command review and `git diff --check`.

## Language, security, and Git completion
- All README files, documentation, and code comments MUST be in English.
- Before completion and before any push, scan working code, relevant untracked files, staged changes, and full Git history across all local refs for sensitive data (tokens, passwords, private keys, and credentials). Use a secret scanner, review findings, and never print secret values. Confirmed exposures block pushing until remediated; revoke/rotate exposed credentials and coordinate any shared-history rewrite.
- Inspect Git status before editing. Preserve unrelated changes, branches, worktrees, and stashes.
- Commit ALL task changes, including required tests and documentation, and integrate them into the primary branch. Remove all task-created temporary branches, worktrees, stashes, patches, and scratch files; retain permanent tests and operational data.
- Finish with no task-owned uncommitted changes. Verify Git status, integration into the primary branch, and branch/worktree cleanup; report unrelated pending work.
- Only after verification, secret review, commits, integration, and cleanup may the primary branch be pushed to GitHub. Do not push temporary branches or force-push automatically.

## Graphify
- For codebase questions, query an existing graph first; verify decisive findings against current source. Use path/explain for focused questions and wiki/report for broad navigation.
- If unavailable, stale, or insufficient, continue with source search and report the limitation.
- Refresh after relevant source changes using the installed skill. Review generated diffs, commit required outputs, and remove task-created disposable caches.
- For /graphify, follow the installed skill first.
