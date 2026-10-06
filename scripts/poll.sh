#!/usr/bin/env bash
# One poll: classify unread participating PR notifications, dedupe, start jobs. Run every 60s.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"
JOB=${PR_AUTOPILOT_JOB:-$DIR/job.sh}

[ -f "$STATE_DIR/paused" ] && { log "paused"; exit 0; }
[ -f "$CONFIG" ] || { log "no config at $CONFIG, run /pr-autopilot:setup"; exit 0; }

LOCK=$STATE_DIR/poll.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then log "previous poll still running"; exit 0; fi
  rm -rf "$LOCK" && mkdir "$LOCK"
fi
echo $$ >"$LOCK/pid"
tmp=$(mktemp -d)
trap 'rm -rf "$LOCK" "$tmp"' EXIT
trap 'report_throttled "poll failed at line $LINENO (see $STATE_DIR/polls.log). Is gh logged in and online?"' ERR

HANDLED=$STATE_DIR/handled.tsv RETRY=$STATE_DIR/retry.tsv
touch "$HANDLED"
me=$(gh api user --jq .login)
dry=$(cfgd dry_run true); mode=live; [ "$dry" = true ] && mode=dry
max=$(cfg '.max_parallel // 2')
flags=(--argjson allow_forks "$(cfgd allow_forks false)"
  --argjson review_enabled "$(cfgd review_enabled true)"
  --argjson fix_enabled "$(cfgd fix_enabled true)")

# Work items: unread notifications on configured repos, plus PRs whose head moved mid-job.
{
  gh api 'notifications?participating=true' | jq -c --slurpfile c "$CONFIG" '
    ($c[0].repos | with_entries(.key |= ascii_downcase)) as $r
    | .[] | select(.subject.type == "PullRequest" and $r[.repository.full_name | ascii_downcase] != null)
    | {thread: .id, reason, repo: .repository.full_name,
       number: (.subject.url | split("/") | last | tonumber), attempt: 0, retry: false}'
  if [ -s "$RETRY" ]; then
    jq -Rc 'split("\t") | {thread: "", reason: .[2], repo: .[0], number: (.[1] | tonumber),
      attempt: (.[3] | tonumber), retry: true}' "$RETRY"
    : >"$RETRY"
  fi
} >"$tmp/items"

running() {
  local n=0 f
  for f in "$STATE_DIR"/running/*; do
    [ -e "$f" ] || continue
    if kill -0 "$(basename "$f")" 2>/dev/null; then n=$((n + 1)); else rm -f "$f"; fi
  done
  echo "$n"
}

while IFS= read -r item; do
  repo=$(jq -r .repo <<<"$item") n=$(jq -r .number <<<"$item")
  reason=$(jq -r .reason <<<"$item")
  gh api "repos/$repo/pulls/$n" >"$tmp/pr"
  gh api --paginate "repos/$repo/pulls/$n/reviews" | jq -s 'add // []' >"$tmp/reviews"
  gh api --paginate "repos/$repo/pulls/$n/comments" | jq -s 'add // []' >"$tmp/comments"
  ev=$(jq -n -c -f "$DIR/classify.jq" --arg me "$me" --arg reason "$reason" --arg repo "$repo" \
    "${flags[@]}" --slurpfile pr "$tmp/pr" --slurpfile reviews "$tmp/reviews" \
    --slurpfile comments "$tmp/comments")
  if [ -n "$(jq -r '.skip // ""' <<<"$ev")" ]; then
    log "skip $repo#$n: $(jq -r .skip <<<"$ev")"; continue
  fi
  key="$mode|$(jq -r .key <<<"$ev")"
  if [ "$(jq -r .retry <<<"$item")" != true ] && grep -qxF "$key" "$HANDLED"; then
    log "already handled $key"; continue
  fi
  if [ "$(running)" -ge "$max" ]; then log "at max_parallel=$max, deferring $repo#$n"; continue; fi

  file="$STATE_DIR/events/$(date +%Y%m%dT%H%M%S)-${repo//\//_}-$n.json"
  jq -c --argjson item "$item" --argjson dry "$dry" \
    '. + {dry_run: $dry, thread: $item.thread, attempt: $item.attempt, reason: $item.reason}' \
    <<<"$ev" >"$file"
  echo "$key" >>"$HANDLED"
  nohup "$JOB" "$file" >/dev/null 2>&1 &
  echo "$mode $key" >"$STATE_DIR/running/$!"
  log "started job for $key (pid $!)"
  # Mark read only now that the job has started. Dry-run leaves your notifications untouched.
  thread=$(jq -r .thread <<<"$item")
  if [ "$mode" = live ] && [ -n "$thread" ]; then
    gh api -X PATCH "notifications/threads/$thread" >/dev/null || log "could not mark $thread read"
  fi
done <"$tmp/items"
log "poll done ($(wc -l <"$tmp/items" | tr -d ' ') items)"
