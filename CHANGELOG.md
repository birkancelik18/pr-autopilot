# Changelog

## 0.7.0

- Fix: wasted attempts. Claude's org monthly spend limit ("You've hit your org's monthly spend limit ... your session limit resets 3:20pm (Europe/Istanbul)"), usage limits and session limits all failed a job as "claude exited with status 1", three times in a row, and the job gave up (only the exact phrase "hit your session limit" was recognised). Any of these is now treated as a limit: the run does not count as an attempt, no job starts until the reset time named in the message (30 minutes when none is given), and you get one notification, not one per job.
- Cost: reviews of big PRs cost $12-16 per run (over `max_cost_usd_per_job`), almost all of it the review passes reading a ~1 MB diff. Now: an incremental review (only the changes since the commit you last reviewed, earlier points re-checked) instead of the whole PR on every round; lock/generated/vendored/minified files become stubs; a diff size cap (`max_diff_kb`, derived from `max_cost_usd_per_job` by default) with a clear note to the model; the rewrite step runs on a cheaper model (`rewrite_model`, default `haiku`) and is skipped once the cost cap is reached (owner notified, nothing posted, no retry). Each Claude run logs a `phase` line with tokens by model.

## 0.6.2

- Fewer pushes per review round (each push costs a full CI run). Only one job per PR runs at a time; a trigger that arrives while one runs (new comment, conflict) waits and is handled by the next job, which starts from the pushed head. Before, a new comment key could start a second parallel fix job on the same PR.
- New config key `fix_settle_seconds` (default 120, 0 = old behaviour): a fix, conflict or CI-fix job on your own PR starts only once the PR has been quiet (no `updated_at` change) for that long, so a burst of review and bot comments lands in one job and one push. Review jobs are not delayed. A string, negative or fractional value stops the poller with a loud report. Limit: fix, conflict and CI-fix are still separate jobs in order.
- New config key `fix_settle_max_seconds` (default 600, whole number, must be >= `fix_settle_seconds`, else a loud report): the settle wait ends at most this long after the PR was first held back, so a PR that never goes quiet still gets its job, which takes every trigger pending at that moment.

## 0.6.1

- New config key `review_max_changed_lines` (additions + deletions as GitHub reports them; missing, null or 0 = no limit). A review request for a larger PR starts no job; you are told once per PR head ("skipped review, N changed lines is over your M-line limit"). A smaller PR or a new head is evaluated again. Fix, conflict and CI-fix jobs on your own PRs are unchanged. A string, negative or fractional value stops the poller with a loud report instead of silently disabling the limit (that report has its own hourly throttle, so another error never swallows it). If a limit is set and GitHub gives no size for a PR, the review is skipped and you are told once per head.

## 0.6.0

- `reviewing_mode` gains `walk` (`off | notify | walk | act`; default still `act`). On a review request nothing is posted on GitHub: the reviewer prepares a private draft (findings with file:line and the head sha), saved locally, and you are told "ready to walk: /pr-autopilot:walk N".
- New `/pr-autopilot:walk <PR>` (any PR, any mode): walks you through the diff in source order, one logical block at a time, with the draft findings next to their block and questions answered from the code at the head. At the end you pick approve / request changes / comment / nothing and which findings to include. It posts only on that pick, pinned to the head it walked; if the head moved it refuses, says so and offers to re-walk the new part.
- `walk` is for `reviewing_mode` only; for `mine_mode` it is an unknown value (treated as notify, loudly). Unknown values stay loud; `/pr-autopilot:mode`, status and setup know `walk`.

- Local CI is removed entirely (it came in with 0.4.0): no `ci-local` runner, no container runner, no local CI record check on reviews, no setup question. GitHub's check runs are the only CI source; the CI fix on your own PRs and the review verdict work from them as before. Old configs keep working: `ci_source`, `ci_container` and `ci_timeout_minutes` are ignored with one clear warning in the poller log (each poll) and in `/pr-autopilot:status`, never an error.

## 0.5.0

- Two independent switches, each `off | notify | act`, default `act` (no change for existing users):
  - `reviewing_mode`: review requests where you are the reviewer.
  - `mine_mode`: reviews and feedback others leave on PRs you wrote.
  - `off` ignores them entirely. `notify` tells you once per event (PR link and a short summary, also in `/pr-autopilot:watch`) and does nothing else: no review posted, no fix, no push. `act` is the old behaviour.
  - `mine_mode` covers review feedback only; merge-conflict and CI fixes on your own PRs stay governed by `conflict_enabled` and `ci_fix_enabled`.
  - An unknown value counts as `notify`, but loudly: the poller logs it and reports it (throttled), and `/pr-autopilot:status` shows the raw value marked "(unknown, treated as notify)". `dry_run` still applies on top of `act`.
- New `/pr-autopilot:mode <reviewing|mine> <off|notify|act>`; `/pr-autopilot:status` shows both; `/pr-autopilot:setup` asks for them.

