---
description: Set what pr-autopilot does for review requests on others' PRs (reviewing) and for feedback on your own PRs (mine): off, notify, walk (reviewing only) or act
argument-hint: <reviewing|mine> <off|notify|walk|act>
---

Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" mode $ARGUMENTS` and show the output. With no arguments, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" status` instead and show only its `reviewing others` line.

- `reviewing`: review requests where you are the reviewer. `mine`: reviews and feedback others leave on PRs you wrote.
- `off`: ignored entirely. `notify`: you are told once per event (PR link and a short summary, also in `/pr-autopilot:watch`), nothing is posted, fixed or pushed. `walk` (`reviewing` only): nothing is posted; a private draft review is prepared and you are told `ready to walk`, then `/pr-autopilot:walk <PR>` walks you through it. `act`: the default, it does the work.
