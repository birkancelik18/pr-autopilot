#!/usr/bin/env bash
# One job: usage job.sh <event.json> (written by poll.sh). Runs headless Claude in a throwaway
# git worktree of the configured clone, then reports the outcome. Never touches your working copy.
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"
EV=$1
g() { jq -r "$1" "$EV"; }
repo=$(g .repo) n=$(g .number) kind=$(g .kind) head=$(g .head) branch=$(g .branch)
title=$(g .title) url=$(g .url) dry=$(g .dry_run) attempt=$(g .attempt) who=$(g .who) cr=$(g '.cr // false')
clone=$(jq -r --arg r "$repo" '.repos | to_entries[] | select(.key | ascii_downcase == ($r | ascii_downcase)) | .value' "$CONFIG")
me=$(gh api user --jq .login)

if [ "$kind" = review ]; then what="$who asked you to review it"
elif [ "$cr" = true ]; then what="$who requested changes on yours"
else what="$who commented on yours"; fi
prefix="PR #$n ($title): $what."
[ "$dry" = true ] && prefix="[DRY RUN] $prefix"

stamp=$(date +%Y%m%dT%H%M%S)
LOG=$STATE_DIR/logs/$stamp-${repo//\//_}-$n-$kind.log
WT=$STATE_DIR/worktrees/${repo//\//_}-$n-$kind-$$
REF=refs/pr-autopilot/$n-$$
BODY=$STATE_DIR/bodies/${repo//\//_}-$n-$$.md
cpid="" wd=""

stop_wd() { [ -n "$wd" ] && { pkill -P "$wd" 2>/dev/null; kill "$wd" 2>/dev/null; wd=""; }; }
cleanup() {
  [ -n "$cpid" ] && kill "$cpid" 2>/dev/null
  stop_wd
  [ -d "$WT" ] && git -C "$clone" worktree remove --force "$WT" 2>/dev/null
  git -C "$clone" update-ref -d "$REF" 2>/dev/null
  rm -f "$STATE_DIR/running/$$"
}
trap cleanup EXIT
trap 'echo "killed (pause or signal)" >>"$LOG"; exit 143' TERM INT

fail() {
  echo "FAILED: $1" >>"$LOG"
  report "$prefix FAILED: $1. Log: $LOG. $url"
  exit 1
}

# Head moved while we worked: nothing was posted; poll.sh re-queues the PR on its next run.
head_moved() {
  if [ "$attempt" -ge 2 ]; then fail "head kept moving, gave up after 3 tries"; fi
  printf '%s\t%s\t%s\t%s\n' "$repo" "$n" "$(g .reason)" "$((attempt + 1))" >>"$STATE_DIR/retry.tsv"
  log "head moved on $repo#$n, re-queued (attempt $((attempt + 1)))"
  exit 0
}

[ -d "$clone/.git" ] || [ -f "$clone/.git" ] || fail "clone path '$clone' is not a git checkout (fix config.json)"
git -C "$clone" fetch -q origin "+pull/$n/head:$REF" >>"$LOG" 2>&1 || fail "git fetch of PR head failed"
[ "$(git -C "$clone" rev-parse "$REF")" = "$head" ] || {
  echo "head moved before start" >>"$LOG"; head_moved
}
git -C "$clone" worktree add -q --detach "$WT" "$head" >>"$LOG" 2>&1 || fail "git worktree add failed"

# --- tool allow/deny lists. dontAsk mode denies anything not allowed. Deny rules are best-effort
# (Claude Code docs: not a security boundary), the real guard is the narrow allow list.
allow=(Read Grep Glob Skill Agent
  "Bash(git diff *)" "Bash(git log *)" "Bash(git show *)" "Bash(git status*)" "Bash(git blame *)"
  "Bash(gh pr view $n *)" "Bash(gh pr diff $n *)" "Bash(gh pr checks $n *)"
  "Bash(gh api repos/$repo/pulls/$n*)" "Bash(gh api repos/$repo/issues/$n/*)"
  "Edit(/$BODY)")
deny=("Bash(gh pr merge *)" "Bash(git push --force*)" "Bash(git push -f*)" "Bash(git push *--force*)"
  "Bash(gh api -*)" "Bash(gh api * -X *)" "Bash(gh api * --method*)" "Bash(gh api * --input*)")
if [ "$dry" = true ]; then
  deny+=("Bash(git push *)" "Bash(gh pr review *)" "Bash(gh pr edit *)" "Bash(gh pr comment *)"
    "Bash(gh api * -f *)" "Bash(gh api * -F *)" "Bash(gh api * --field*)" "Bash(gh api * --raw-field*)")
fi
if [ "$kind" = review ]; then
  [ "$dry" = true ] || allow+=("Bash(gh pr review $n --repo $repo *)")
  skill=review-pr
else
  allow+=("Edit(/$WT/**)" "Bash(git add *)" "Bash(git commit *)")
  while IFS= read -r t; do allow+=("Bash($t)"); done < <(jq -r '(.test_commands // ["npm run lint*",
    "npm run test*", "npm test*", "npm run typecheck*", "npx vitest*", "npx eslint*", "pytest*",
    "uv run pytest*", "uv run ruff*", "ruff *", "mypy*", "make test*", "make lint*", "go test*",
    "cargo test*"])[]' "$CONFIG")
  if [ "$dry" != true ]; then
    allow+=("Bash(git push origin HEAD:refs/heads/$branch)" "Bash(gh pr edit $n --repo $repo --add-reviewer *)"
      "Bash(gh pr comment $n --repo $repo *)")
  fi
  skill=address-review
fi
join() { local IFS=,; echo "$*"; }

prompt="/pr-autopilot:$skill repo=$repo pr=$n head=$head branch=$branch dry_run=$dry me=$me body_file=$BODY"
tmo=$(cfg '.job_timeout_minutes // 30')
echo "# $stamp $kind $repo#$n head=$head dry_run=$dry" >"$LOG"
cd "$WT" || fail "cannot enter worktree"
claude -p "$prompt" --plugin-dir "$PLUGIN_ROOT" --permission-mode dontAsk \
  --allowedTools "$(join "${allow[@]}")" --disallowedTools "$(join "${deny[@]}")" \
  --output-format json --no-session-persistence >"$LOG.json" 2>>"$LOG" &
cpid=$!
(sleep $((tmo * 60)); echo "timeout after ${tmo}m" >>"$LOG"; kill "$cpid" 2>/dev/null) 2>/dev/null &
wd=$!; disown "$wd"
wait "$cpid"; rc=$?
stop_wd; cpid=""
jq -r '.result // empty' "$LOG.json" >>"$LOG" 2>/dev/null

[ "$rc" -eq 0 ] || fail "claude exited with status $rc (143 or 137 means timeout or pause)"
[ "$(jq -r '.is_error // false' "$LOG.json")" = false ] || fail "claude reported an error: $(jq -r '.result // "?"' "$LOG.json" | head -c 200)"
outcome=$(jq -r '.result // ""' "$LOG.json" | grep '^OUTCOME:' | tail -1 | sed 's/^OUTCOME: *//')
[ -n "$outcome" ] || fail "skill finished without an OUTCOME line"
[ "$outcome" = head-moved ] && head_moved
case $outcome in FAILED*) fail "${outcome#FAILED: }" ;; esac
report "$prefix $outcome $url"
