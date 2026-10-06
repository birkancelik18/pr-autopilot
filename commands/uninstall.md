---
description: Remove the pr-autopilot poller (launchd job, systemd timer or cron entry) and its installed copy
---

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ctl.sh" pause` to stop running jobs, then `bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-scheduler.sh" uninstall`.
2. Ask whether to also delete the config (`~/.config/pr-autopilot`) and the state and logs (`~/.local/state/pr-autopilot`). Delete them only if the user says yes.
3. Tell the user to finish with `claude plugin uninstall pr-autopilot@pr-autopilot` (and optionally `claude plugin marketplace remove pr-autopilot`).
