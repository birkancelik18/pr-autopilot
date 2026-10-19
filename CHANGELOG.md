# Changelog

## 0.5.0

- Two independent switches, each `off | notify | act`, default `act` (no change for existing users):
  - `reviewing_mode`: review requests where you are the reviewer.
  - `mine_mode`: reviews and feedback others leave on PRs you wrote.
  - `off` ignores them entirely. `notify` tells you once per event (PR link and a short summary, also in `/pr-autopilot:watch`) and does nothing else: no review posted, no fix, no push, no local CI run. `act` is the old behaviour.
  - `mine_mode` covers review feedback only; merge-conflict and CI fixes on your own PRs stay governed by `conflict_enabled` and `ci_fix_enabled`.
  - An unknown value counts as `notify`, but loudly: the poller logs it and reports it (throttled), and `/pr-autopilot:status` shows the raw value marked "(unknown, treated as notify)". `dry_run` still applies on top of `act`.
- New `/pr-autopilot:mode <reviewing|mine> <off|notify|act>`; `/pr-autopilot:status` shows both; `/pr-autopilot:setup` asks for them.

## 0.4.0

Local CI as the CI source; a teammate's PR code never runs on this Mac.
