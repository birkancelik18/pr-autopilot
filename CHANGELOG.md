# Changelog

## Unreleased

- New config key `review_max_changed_lines` (additions + deletions as GitHub reports them; missing, null or 0 = no limit). A review request for a larger PR starts no job; you are told once per PR head ("skipped review, N changed lines is over your M-line limit"). A smaller PR or a new head is evaluated again. Fix, conflict and CI-fix jobs on your own PRs are unchanged. A string, negative or fractional value stops the poller with a loud report instead of silently disabling the limit.

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

