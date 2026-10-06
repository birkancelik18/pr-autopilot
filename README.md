# pr-autopilot

A Claude Code plugin that handles two chores on GitHub, as you:

- Someone asks you to review a PR: it reviews it with three independent passes (bugs, security, project conventions), blends the findings and posts one APPROVE or REQUEST_CHANGES review.
- Someone requests changes (or leaves review comments) on a PR you wrote: it fixes the genuine points on your PR branch, pushes, replies on each thread and re-requests review.

It is not a long-running agent. A tiny shell poller runs every 60 seconds, asks GitHub for your unread notifications, and only starts a headless `claude -p` when there is a new event. Everything runs with your own `gh` login and your own `claude` login, so everything it posts appears as you and the usage counts against your own Claude plan. Each job works in a separate `git worktree`, never in your working copy. You get a macOS notification (and optionally a Slack message) for every outcome, failures included.

## Requirements

`gh` (logged in: `gh auth login`), `claude` (logged in with your own account), `jq`, `git`, `bash`, and `curl` if you want Slack. macOS is the target; Linux works with a systemd user timer or cron. Each watched repo needs a local clone with an `origin` remote.

## Install (3 steps)

```bash
claude plugin marketplace add <git url of this repo>     # or /plugin marketplace add <url> inside Claude Code
claude plugin install pr-autopilot@pr-autopilot
claude                                                   # then run: /pr-autopilot:setup
```

`/pr-autopilot:setup` checks your logins, asks which repos to watch and where their clones are, writes `~/.config/pr-autopilot/config.json`, and installs the 60-second launchd job (macOS) or systemd timer / cron entry (Linux). Re-run it after updating the plugin to refresh the installed copy (`~/.local/share/pr-autopilot/plugin`).

## Try it in dry-run

Setup leaves `"dry_run": true`. In dry-run the jobs do the full review or fix and then stop: nothing is posted, nothing is pushed, your notifications are not marked read. You still get the notification with what it would have done ("I would have posted REQUEST_CHANGES: ...") and the full log in `~/.local/state/pr-autopilot/logs/`. Ask a colleague to request your review on a test PR, wait a minute, and check `/pr-autopilot:status`.

## Turn on posting

Edit `~/.config/pr-autopilot/config.json` and set `"dry_run": false`. No restart needed. Events already handled in dry-run are run again once in live mode (dry-run and live dedupe separately), so pending unread review requests get real reviews.

## Config

See `config.example.json`. `repos` maps `owner/name` to the local clone path. Other keys: `dry_run` (default true), `review_enabled`, `fix_enabled` (default true), `allow_forks` (review PRs from forks, default false), `max_parallel` (default 2), `job_timeout_minutes` (default 30), `slack_webhook`, `test_commands` (Bash patterns the fix job may run, for example `"npm run test*"`; sensible defaults exist).

## Day to day

- `/pr-autopilot:status` shows last polls, running and recent jobs, failures.
- `/pr-autopilot:pause` is the kill switch: the poller does nothing and running jobs are stopped. `/pr-autopilot:resume` undoes it.

## Uninstall

```bash
# in Claude Code
/pr-autopilot:uninstall                      # removes the launchd job / timer / cron entry and the installed copy
claude plugin uninstall pr-autopilot@pr-autopilot
claude plugin marketplace remove pr-autopilot
```

Config and logs stay in `~/.config/pr-autopilot` and `~/.local/state/pr-autopilot` until you delete them (the command asks).

## Safety

It never merges, never force-pushes, pushes only to the PR's own branch with a plain `git push`, ignores repos not in your config, and skips draft, closed and merged PRs and (by default) fork PRs. Fix jobs never run on your own PRs from forks. Jobs run in `dontAsk` permission mode with a narrow allow list (read tools, `git`, `gh` scoped to that one PR, your test commands, edits inside the job's worktree); anything else is denied. The deny rules for `gh api` write forms are best effort (Claude Code documents Bash deny rules as not a security boundary), the allow list is the real limit. PR text is untrusted and the skills tell Claude to treat it as data, but a determined prompt injection in a PR is a risk to weigh before you enable posting for repos with outside contributors.

## Known limits

- The machine must be awake and online. Events that arrive while it sleeps are handled at the next poll as long as the notification is still unread.
- GitHub notifications for review requests and participating threads must be on for your account. The poller reads only unread `participating` notifications; if you read a notification in the browser first, pr-autopilot never sees it.
- Review dedupe is per (PR, head commit). A re-request on an unchanged head commit does not trigger a second review. Fix dedupe is per (latest change-request review id, latest comment id).
- If the PR head moves during a job, nothing is posted and the PR is retried on the next poll (3 tries).
- It reads each PR's reviews and comments on every poll while its notification is unread, which is a few API calls per PR per minute.
- It uses your own Claude usage. Three review passes plus subagents is not free; lower `max_parallel` or pause when needed.
- Review verdicts are only as good as the model; read the first few in dry-run before trusting it.
- Not verified on a real PR yet: the headless `claude -p` run with `--plugin-dir` was exercised only against a fake `claude` in the tests.

## Tests

```bash
bash tests/run.sh
```

No network: the poller and the job runner run against a fake `gh`, a fake `claude` and recorded JSON fixtures.
