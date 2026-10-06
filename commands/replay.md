---
description: Let pr-autopilot also act on older unread review requests and comments that predate going live
---

Explain to the user that after `dry_run` is switched to false, pr-autopilot only acts on PRs updated after that moment, so the existing backlog is not reviewed in one burst. Ask whether they really want the backlog processed now (it may start many Claude jobs, up to `max_parallel` at a time, each posting as them). Only if they confirm, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" replay` and show the output.
