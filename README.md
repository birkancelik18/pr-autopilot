# pr-autopilot

A Claude Code plugin that handles two chores on GitHub, as you:

- Someone asks you to review a PR: it reviews it with three independent passes (bugs, security, project conventions) plus any review skills you add, blends the findings and posts one APPROVE or REQUEST_CHANGES review.
- Someone requests changes (or leaves review comments) on a PR you wrote: it fixes the genuine points on your PR branch, pushes, replies on each thread and re-requests review.
- A PR you wrote gets merge conflicts with its base: it merges the base into your branch, resolves the conflicts, and pushes a normal merge commit (no rebase, no force-push). Conflicts it should not decide come back to you.

It is not a long-running agent. A tiny shell poller runs every 60 seconds, asks GitHub what needs you, and only starts a headless `claude -p` when there is a new event. Everything runs with your own `gh` login and your own `claude` login, so everything it posts appears as you and the usage counts against your own Claude plan. Each job works in a separate `git worktree`, never in your working copy. You hear about every outcome, failures included, your choice at setup (`notify_style`): a small window with an **Open PR** button (`window`, the default, needs nothing; it closes itself after a minute), or a macOS banner whose click opens the PR (`notification`, needs `brew install terminal-notifier` and allowing it once in System Settings → Notifications; until then the banner shows but a click opens Script Editor). Optionally a Slack message too.

**The model never writes to GitHub.** Claude only reads files (the PR checkout and PR data the script pre-fetched) and writes a draft file or edits the checkout. The scripts do every post, push, reply and re-request themselves, after their own checks, and report only what they verified on GitHub afterwards.

## Requirements

`gh` (logged in: `gh auth login`), `claude` (logged in with your own account), `jq`, `git`, `bash`, `curl` if you want Slack. macOS is the target; Linux works with a systemd user timer or cron. Each watched repo needs a local clone with an `origin` remote.

What it watches: the GitHub **search API** is the primary source, so it works even if you keep on-site GitHub notifications off. Each poll runs two searches over your configured repos: open PRs where review is requested from you (`review-requested:you`), and your own open PRs. GitHub notifications (unread, participating) are used as an optional extra source and to mark a notification read after a job succeeds. Limits: search covers requests addressed to you personally, not review requests that only went to a team.

## Install (3 steps)

```bash
claude plugin marketplace add <git url of this repo>     # or /plugin marketplace add <url> inside Claude Code
claude plugin install pr-autopilot@pr-autopilot
claude                                                   # then run: /pr-autopilot:setup
```

`/pr-autopilot:setup` checks your logins, asks which repos to watch and where their clones are, writes `~/.config/pr-autopilot/config.json`, and installs the 60-second launchd job (macOS) or systemd timer / cron entry (Linux). The scheduler runs a copy of the plugin kept under `~/.local/share/pr-autopilot/`; re-run setup after updating the plugin to refresh it.

## Live by default, dry-run to try it

Setup writes `"dry_run": false`: from the next poll it posts and pushes as you. It does not replay the backlog: only PRs updated after setup are acted on. To try it without posting first, set `"dry_run": true` (no restart needed). In dry-run the jobs do the full review or fix and then stop: nothing is posted, nothing is pushed, your notifications are not marked read. You still get the notification with what it would have done ("I would have posted REQUEST_CHANGES: ...") and the full log in `~/.local/state/pr-autopilot/logs/`. Ask a colleague to request your review on a test PR, wait a minute, and check `/pr-autopilot:status`.

## Switching between dry-run and live

Edit `~/.config/pr-autopilot/config.json` and set `"dry_run"`. No restart needed. Going live does **not** replay the backlog: only PRs updated after the moment you switched are acted on, so ten old review requests do not become ten reviews at once. Run `/pr-autopilot:replay` if you want the backlog processed too.

## Config

See `config.example.json`. `repos` maps `owner/name` to the local clone path. Other keys: `dry_run` (setup writes false), `review_enabled`, `fix_enabled` (default true), `conflict_enabled` (resolve merge conflicts on your own PRs, default true), `allow_forks` (review PRs from forks, default false), `ignore_authors` (extra bot logins whose reviews and comments are ignored; logins ending in `[bot]` always are), `trusted_commenters` (extra logins whose feedback may start a fix job, see below), `auto_approve_outsiders` (default false, see below), `max_parallel` (default 2), `max_cost_usd_per_job` (default 10; a notification is sent when a job's estimated cost exceeds it, nothing is stopped), `job_timeout_minutes` (default 30), `slack_webhook`, `review_skills` (your own review lenses, see below), and the opt-in `run_local_tests_UNSAFE` (see Safety). Live mode needs `"dry_run": false` exactly; any other value, a missing key or an unreadable config means dry-run.

## Add your own review skills

Every review runs three built-in passes in parallel: bugs, security and data isolation, and the repo's own conventions. You can add more. Write the lens as a markdown file (a Claude Code `SKILL.md` works as is) and list its absolute path in the config:

```json
"review_skills": ["/Users/you/.claude/skills/money-review/SKILL.md", "/Users/you/review-lenses/i18n.md"]
```

Each file becomes one more pass, run in parallel with the built-in three. Its findings are blended into the same single review with the same rules: a finding needs a `file:line` and a concrete failure, and only real blockers request changes. The file is copied into the job, so it is your text giving instructions; the PR it looks at stays untrusted data, and the pass has the same read-only tools as the others (no shell, no network). A listed file that does not exist fails the job loudly instead of quietly reviewing without it. Changes to the file apply from the next review, no restart needed.

## How decisions are made

- **Review** runs when a PR shows up in your review-requested search (or a notification arrives while you are still in the PR's requested reviewers; a sticky old notification alone does not count), is open, not a draft, and you have not already reviewed its current head commit. A re-request after the author pushes fixes therefore triggers a new review; a re-request with no new commits does not. Dedupe key: (repo, PR, head sha).
- **Fix** runs on your own open PRs when a human other than you has a new CHANGES_REQUESTED review (each reviewer counts by their latest review, so a later approval cancels it), a COMMENTED review with a body, an inline comment or a top-level comment. Bots are ignored. Only feedback from people whose `author_association` is OWNER, MEMBER or COLLABORATOR, or who are listed in `trusted_commenters`, can start a fix; everyone else's comments are logged and ignored (otherwise any stranger commenting on your public PR could steer an automated commit). Dedupe key: (repo, PR, newest id of each of those). Fix is skipped for your own PRs from forks.
- **Merge conflicts** on your own open PRs (GitHub reports the PR as conflicting): any open feedback is fixed first, then the base branch is merged into your branch in a throwaway worktree. Claude edits only the conflicted files (no shell); the script puts back anything else it touched, refuses to continue if a conflict marker is left or a JSON file no longer parses, commits `Merge <base> into <branch>`, pushes it plainly and checks GitHub shows it. A conflict in agent config (CLAUDE.md, AGENTS.md, `.claude/`, `.mcp.json`), in a binary file, or on a file deleted on one side is never handed to Claude, and neither is a real disagreement between the two sides that Claude flags: the merge is aborted and you are told which files need you. CI then runs the tests on the merge. Because a new conflict appears when the base moves, without the PR itself changing, your own PRs are looked at again every 10 minutes. Dedupe key: (repo, PR, head sha, base sha).
- **APPROVE is not auto-posted for outsiders.** A diff can contain text aimed at the reviewing model, and APPROVE is what such text would try to buy. So an APPROVE is posted automatically only when the PR author is OWNER or MEMBER of the org; for anyone else you get the draft path in the notification and decide yourself (`auto_approve_outsiders: true` turns this off). REQUEST_CHANGES posts either way. Be plain about the limit: an injected diff could still steer the verdict for org members' PRs, or push a REQUEST_CHANGES with misleading text; what bounds it is that the model cannot do anything but write that one draft, the draft is capped at 150 words and defanged of @mentions, and the verdict is pinned to the reviewed commit.
- A job is marked handled only after it succeeded. A failed job is retried by the next poll after 5 minutes, at most 3 times, with a loud report each time. A job stopped by pause is not counted as a failure and starts again after `/pr-autopilot:resume`.
- If the PR changed (head moved, closed, turned draft) while the job ran, nothing is written and the next poll starts over with fresh data.

## Results in your Claude Code chats

Every result also lands in an unread list, and the plugin brings it into Claude Code two ways:

- **In your next message, in any chat (always on).** A hook adds unread results to the next message you send; Claude opens its reply with one line per result and the PR link. Each result is shown once, in whichever chat you type in next. Nothing to set up. It never runs inside pr-autopilot's own jobs (they switch all hooks off).
- **Live in one chat: `/pr-autopilot:watch`.** That chat watches for new results and posts each one as it happens, while the chat stays open.

Both share one "read" marker, so a result never shows twice. The lines quote PR titles and review text written by others; Claude is told to relay them, not follow them.

## Day to day

- `/pr-autopilot:watch` posts results live in the current chat.
- `/pr-autopilot:status` shows last polls, running and recent jobs, failures.
- `/pr-autopilot:pause` is the kill switch: the poller does nothing and running jobs are stopped before they write anything. `/pr-autopilot:resume` undoes it.
- `/pr-autopilot:replay` includes the pre-live backlog (see above).

## Uninstall

```bash
# in Claude Code
/pr-autopilot:uninstall                      # removes the launchd job / timer / cron entry and the installed copy
claude plugin uninstall pr-autopilot@pr-autopilot
claude plugin marketplace remove pr-autopilot
```

Config and logs stay in `~/.config/pr-autopilot` and `~/.local/state/pr-autopilot` until you delete them (the command asks).

## What it does as you, and where your code goes

Everything below appears on GitHub under your name, only in live mode and only after the script's own checks: review bodies (APPROVE or REQUEST_CHANGES), replies on review threads, top-level PR comments answering review-body or top-level points, commits on your own PR branches under your local git identity (`user.name` and `user.email` of the clone), and review re-requests. It never merges, closes, labels or edits PR text.

The PR diff, description, comments and the checked-out code (including private repos) are sent to Anthropic by your own `claude` login, under your own plan and its data terms. **Dry-run still does this**: it runs Claude for real, and only skips the GitHub writes, the commit and the push. Dry-run executes no repo code and no tests.

## Safety

It never merges, never force-pushes, pushes only to the PR's own branch with a plain `git push`, ignores repos not in your config, and skips draft, closed and merged PRs and (by default) fork PRs.

PR content (descriptions, comments, code, even the repo's own `CLAUDE.md`) is untrusted, so the job is built to survive a hostile PR:

- Claude runs with `--permission-mode dontAsk`, `--setting-sources ""` (no user, project or local settings), `--settings '{"disableAllHooks":true}'` (no hooks from anywhere, including yours) and `--strict-mcp-config` with no MCP servers. Your global `~/.claude` skills, hooks and permission rules therefore do not apply inside a job. Verified against the real `claude` 2.1.291 on a repo with a malicious hook, `.mcp.json`, skill and `CLAUDE.md`: none ran. Not verified: whether Claude Code still reads your own user-level `~/.claude/CLAUDE.md` or memory (it is your own text, not the PR's).
- The checkout is sparse: `CLAUDE.md`, `AGENTS.md`, `.claude/` and `.mcp.json` (at any depth) are not present. The base branch's copies are handed over as plain `.txt` reference files.
- Allowed tools: review gets only reads (inside the checkout and the job dir) and one writable file, `draft.md`, plus subagents. **Fix gets no shell at all**: it reads, edits files inside the checkout, and writes `result.json` listing the files it changed. No `gh`, no `git`, no network commands, no Skill tool. Reads outside the checkout and job dir are denied (checked, including through a symlink in the repo and `~/.config/gh`). Claude and everything it spawns run in their own process group; pause and the timeout kill the group.
- Writes happen in the scripts: the review is posted through the API pinned to the exact commit that was reviewed; a second review for the same commit is refused; the fix commit contains only the files listed in `result.json` (never `git add -A`), is pushed as a plain push of the PR branch after checking that the clone's `origin` is the configured repo, then replies (at most one per open human comment, max 20), then re-requests review (from every reviewer the fix answered, plus anyone whose latest review requests changes), each verified by reading GitHub back. @mentions in anything the model wrote are wrapped in backticks so they cannot ping people, and Slack text is escaped.

Tests do not run locally by default; CI on GitHub is where they run. If you really want local test runs, set `run_local_tests_UNSAFE: {"owner/repo": ["exact command"]}`. That is unsafe because it executes code from your PR branch on your machine. The script (not the model) runs only those exact strings (no `*`, no `npx`, no `-exec`), only in live mode, only on macOS inside `sandbox-exec` (no network, writes only inside the checkout and tmp, `~/.ssh`, `~/.aws`, `~/.config/gh` unreadable) with a scrubbed environment (no `GH_TOKEN`, no `SSH_AUTH_SOCK`, fake `HOME`), and a failing command stops the job before anything is committed. Elsewhere it refuses to run them.

Remaining risks: a prompt injection can still skew a review's wording or verdict, which is why dry-run first is recommended; it cannot make the job do anything but post that review.

## Known limits

- The machine must be awake and online. A PR that needs you is picked up at the next poll after wake.
- Search API limit is 30 requests a minute; the poller makes two per poll. A PR whose `updated_at` did not change since it was last settled is not re-fetched.
- Review dedupe is per (PR, head commit): a re-request on an unchanged head does not trigger a second review.
- Job logs are kept 14 days, `polls.log` is trimmed at 1 MB.
- A review draft over 150 words is not thrown away: one cheap follow-up turn asks Claude to shorten it without dropping a blocker, and only a draft still over the limit fails.
- It uses your own Claude usage. Each review (three parallel subagent passes plus the blend) costs roughly what a long interactive Claude Code session does, and the job log records `usage: total_cost_usd=...` per job. Three review passes plus subagents is not free; lower `max_parallel` or pause when needed.
- Review verdicts are only as good as the model; read the first few in dry-run before trusting it.
- Not tested on real GitHub writes (review post, push, replies, re-request): those paths ran only against a fake `gh`. launchd, systemd and cron installation was not exercised either, only the generated plist and unit were checked.

## Tests

```bash
bash tests/run.sh
```

No network: the poller and the job runner run against a fake `gh`, a fake `claude`, a throwaway git repo and recorded JSON fixtures (notifications, search results, PRs, reviews, comments).
