---
description: Check gh, claude and jq, write the pr-autopilot config interactively, and install the 60-second poller (dry-run by default)
---

Set up pr-autopilot for this user. Do these steps in order and stop with a clear message if one fails.

1. Check requirements by running: `gh auth status`, `jq --version`, `git --version`, `claude --version`. If `gh` is not logged in, tell the user to run `gh auth login` and stop. Note that `claude` must be logged in with the user's own account (run `claude auth status` if available).
2. Run `gh api user --jq .login` and tell the user that everything pr-autopilot posts will appear as that login.
3. Ask the user which repos to watch (`owner/name`) and the absolute path of their local clone of each (verify each path is a git checkout whose `origin` points at that repo; the clone must have an `origin` remote). Optionally ask for a Slack incoming-webhook URL, and `max_parallel` (default 2).
4. Write `~/.config/pr-autopilot/config.json` (create the directory) following `${CLAUDE_PLUGIN_ROOT}/config.example.json`. Set `"dry_run": true`. If a config already exists, show it and ask before overwriting.
5. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-scheduler.sh" install`. It copies the plugin to `~/.local/share/pr-autopilot/plugin` and installs a launchd job (macOS) or systemd user timer / cron entry (Linux) that runs the poller every 60 seconds.
6. Tell the user: it is in DRY-RUN mode, it will review and fix but post and push nothing, results appear as notifications and in `/pr-autopilot:status`, and to switch on posting they set `"dry_run": false` in the config. Say that going live later does not replay the backlog (use `/pr-autopilot:replay` for that). Remind them to re-run `/pr-autopilot:setup` after updating the plugin so the installed copy is refreshed, and that GitHub notifications for review requests must be enabled.
