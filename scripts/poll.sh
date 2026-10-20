#!/usr/bin/env bash
# One poll: classify unread participating PR notifications, dedupe, start jobs. Run every 60s.
# State files (STATE_DIR): handled.tsv (keys of jobs that succeeded), failed.tsv (one line per failed
# attempt: epoch<TAB>key), running/<pid> (key of live jobs), mode + live_since (see below).
# No `set -e`: one bad PR must not abort the poll, every step checks its own result.
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"
JOB=${PR_AUTOPILOT_JOB:-$DIR/job.sh}
MAX_ATTEMPTS=3 RETRY_AFTER=300 MAX_CI_FIXES=3 POLL_FAIL_REPORT=5 FAIL_KEEP=$((7 * 86400))

is_paused && { log "paused"; exit 0; }
[ -f "$CONFIG" ] || { log "no config at $CONFIG, run /pr-autopilot:setup"; exit 0; }
jq -e '.repos | type == "object" and length > 0' "$CONFIG" >/dev/null 2>&1 ||
  { report_throttled "pr-autopilot: $CONFIG is unreadable or has no repos, doing nothing"; exit 1; }

# review_max_changed_lines: a non-negative integer (0 or missing = no limit). Anything else fails loudly:
# silently ignoring a typo would review the PRs the owner wanted skipped.
jq -e '.review_max_changed_lines | . == null or (type == "number" and . >= 0 and . == floor)' "$CONFIG" >/dev/null 2>&1 ||
  { report_throttled "pr-autopilot: review_max_changed_lines in $CONFIG must be a whole number, 0 or more (got $(jq -c .review_max_changed_lines "$CONFIG")), doing nothing" last_config_error_report; exit 1; }

# fix_settle_seconds: a non-negative whole number (default 120, 0 = start fix jobs at once). Loud for the same reason.
jq -e '.fix_settle_seconds | . == null or (type == "number" and . >= 0 and . == floor)' "$CONFIG" >/dev/null 2>&1 ||
  { report_throttled "pr-autopilot: fix_settle_seconds in $CONFIG must be a whole number, 0 or more (got $(jq -c .fix_settle_seconds "$CONFIG")), doing nothing" last_config_error_report; exit 1; }

# fix_settle_max_seconds: whole number (default 600), at least fix_settle_seconds: the longest a PR's fix job is held back.
jq -e '(.fix_settle_max_seconds | . == null or (type == "number" and . >= 0 and . == floor))
  and ((.fix_settle_max_seconds // 600) >= (.fix_settle_seconds // 120))' "$CONFIG" >/dev/null 2>&1 ||
  { report_throttled "pr-autopilot: fix_settle_max_seconds in $CONFIG must be a whole number, 0 or more, and not below fix_settle_seconds (got $(jq -c .fix_settle_max_seconds "$CONFIG") with fix_settle_seconds $(jq -c '.fix_settle_seconds // 120' "$CONFIG")), doing nothing" last_config_error_report; exit 1; }

# Lock: mkdir is atomic; the pid file is written via temp+mv so a reader never sees it half written.
LOCK=$STATE_DIR/poll.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null && { log "previous poll still running"; exit 0; }
  elif [ -n "$(find "$LOCK" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
    log "lock just created by another poll, grace period"; exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { log "lost the lock race"; exit 0; }
fi
echo $$ >"$LOCK/pid.tmp" && mv "$LOCK/pid.tmp" "$LOCK/pid"
tmp=$(mktemp -d)
trap 'rm -rf "$LOCK" "$tmp"' EXIT

HANDLED=$STATE_DIR/handled.tsv FAILED=$STATE_DIR/failed.tsv SEEN=$STATE_DIR/seen.tsv
touch "$HANDLED" "$FAILED" "$SEEN"
[ "$(wc -l <"$SEEN")" -gt 5000 ] && : >"$SEEN"
gc

# A poll-level failure is usually a network blip (gh() already retried): stay quiet, and tell the user
# only when POLL_FAIL_REPORT polls in a row failed.
poll_fail() { # poll_fail <message>
  local n; n=$(($(cat "$STATE_DIR/poll_failures" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$STATE_DIR/poll_failures"
  if [ "$n" -ge "$POLL_FAIL_REPORT" ]; then report_throttled "$1 ($n polls in a row)"
  else log "WARN $1 (poll $n of $POLL_FAIL_REPORT, not reported yet)"; fi
  exit 1
}

me=$(gh api user --jq .login 2>>"$STATE_DIR/polls.log")
[ -n "$me" ] || poll_fail "poll failed: gh api user returned nothing. Is gh logged in and online?"
# Fail closed: live only when dry_run is exactly false; anything else (missing, null, "false") is dry.
dry=$(jq -r 'if .dry_run == false then "false" else "true" end' "$CONFIG"); mode=live; [ "$dry" = true ] && mode=dry
max=$(cfgd max_parallel 2) settle_s=$(cfgd fix_settle_seconds 120) settle_max_s=$(cfgd fix_settle_max_seconds 600)

# Going live must not replay the backlog: remember when dry_run was switched off and only act on
# PRs (search results or notifications) updated after that. /pr-autopilot:replay resets live_since to the epoch.
if [ "$mode" = live ] && [ "$(cat "$STATE_DIR/mode" 2>/dev/null)" != live ]; then
  date -u +%FT%TZ >"$STATE_DIR/live_since"
  log "dry_run switched off, acting only on notifications updated after $(cat "$STATE_DIR/live_since")"
fi
echo "$mode" >"$STATE_DIR/mode"
live_since=$(cat "$STATE_DIR/live_since" 2>/dev/null || echo 1970-01-01T00:00:00Z)

# Two switches, each off | notify | walk | act (default act): reviewing_mode = review requests where I am the
# reviewer, mine_mode = review feedback on PRs I wrote. off: ignored. notify: one report per event
# (notify_only below), nothing posted, fixed or pushed. act: today's behaviour. They combine with
# review_enabled / fix_enabled (false there still means nothing happens).
rmode=$(mode_of reviewing_mode) mmode=$(mode_of mine_mode)
for k in reviewing_mode mine_mode; do # a typo acts as notify, but never silently
  mode_ok "$k" "$(cfgd "$k" '"act"')" || {
    log "WARN $k \"$(cfgd "$k" '"act"')\" is not $(mode_list "$k"), treating it as notify"
    report_throttled "$k \"$(cfgd "$k" '"act"')\" is not $(mode_list "$k"), treating it as notify"; }
done
rok=$([ "$rmode" != off ] && cfgd review_enabled true || echo false)
fok=$([ "$mmode" != off ] && cfgd fix_enabled true || echo false)
# Local CI was removed in 0.6.0: old keys are ignored, once per poll in the log, never a crash.
legacy=$(legacy_ci_keys)
[ -z "$legacy" ] || log "WARN config key(s) $legacy ignored: local CI was removed, GitHub checks are the only CI source"

flags=(--argjson allow_forks "$(cfgd allow_forks false)"
  --argjson review_enabled "$rok"
  --argjson fix_enabled "$fok"
  --argjson conflict_enabled "$(cfgd conflict_enabled true)"
  --argjson ci_enabled "$(cfgd ci_fix_enabled true)"
  --argjson ignore "$(jq -c '.ignore_authors // []' "$CONFIG")"
  --argjson trusted "$(jq -c '.trusted_commenters // []' "$CONFIG")"
  --argjson review_bots "$(review_bots)"
  --argjson review_max "$(cfgd review_max_changed_lines 0)")
# Feedback-fix cap (config max_feedback_fixes {per_head, per_pr}): a review bot and the fixer answering
# each other must not loop. job.sh records each finished fix in fixes.tsv: "mode|repo|n<TAB>head".
MAX_FIX_HEAD=$(jq -r '(.max_feedback_fixes | objects | .per_head) // 3' "$CONFIG")
MAX_FIX_PR=$(jq -r '(.max_feedback_fixes | objects | .per_pr) // 6' "$CONFIG")
[[ $MAX_FIX_HEAD =~ ^[0-9]+$ ]] || MAX_FIX_HEAD=3
[[ $MAX_FIX_PR =~ ^[0-9]+$ ]] || MAX_FIX_PR=6

# Sources of PRs to look at. Primary: the search API (works even when on-site notifications are off),
# one query per kind per poll, covering all configured repos (search is limited to 30 calls/min).
# Optional extra: unread participating notifications (also lets us mark them read after success).
search() { # search <qualifier> <reason>: all pages, over each repo chunk (query limit is 256 chars)
  local chunk q page out n
  while IFS= read -r chunk; do
    q="is:pr is:open archived:false $1 $chunk"
    for page in 1 2 3 4 5; do
      out=$(gh api "search/issues?per_page=100&page=$page&q=$(jq -rn --arg q "$q" '$q | @uri')" 2>>"$STATE_DIR/polls.log") || return 1
      jq -c --arg reason "$2" '.items[] | {thread: "", reason: $reason, src: "search",
        repo: (.repository_url | sub(".*/repos/"; "")), number, updated_at}' <<<"$out" || return 1
      [ "$(jq '.items | length' <<<"$out")" -ge 100 ] || break
    done
  done < <(repo_chunks $((250 - ${#1} - 30)))
}
{
  search "review-requested:$me" review_requested && search "author:$me" author
} >"$tmp/search" || poll_fail "poll failed: GitHub search failed (see $STATE_DIR/polls.log)"
echo 0 >"$STATE_DIR/poll_failures"
if ! gh api --paginate 'notifications?participating=true&per_page=50' 2>>"$STATE_DIR/polls.log" |
  jq -s -c --slurpfile c "$CONFIG" '
    ($c[0].repos | with_entries(.key |= ascii_downcase)) as $r
    | (add // [])[] | select(.subject.type == "PullRequest" and $r[.repository.full_name | ascii_downcase] != null)
    | {thread: .id, reason, src: "notif", repo: .repository.full_name, updated_at,
       number: (.subject.url | split("/") | last | tonumber)}' >"$tmp/notif"; then
  log "WARN could not list notifications, continuing with search only"; : >"$tmp/notif"
fi
# One item per PR: keep a notification thread id if any, review_requested wins, newest updated_at.
cat "$tmp/search" "$tmp/notif" | jq -s -c 'group_by([(.repo | ascii_downcase), .number])[]
  | {thread: (map(.thread) | map(select(. != "")) | first // ""),
     reason: (if any(.reason == "review_requested") then "review_requested" else .[0].reason end),
     via_search: any(.src == "search" and .reason == "review_requested"),
     repo: .[0].repo, number: .[0].number, updated_at: (map(.updated_at) | max)}' >"$tmp/items"

running() {
  local n=0 f
  for f in "$STATE_DIR"/running/*; do
    [ -e "$f" ] || continue
    if kill -0 "$(basename "$f")" 2>/dev/null; then n=$((n + 1)); else rm -f "$f"; fi
  done
  echo "$n"
}

key_running() {
  local f
  for f in "$STATE_DIR"/running/*; do
    [ -e "$f" ] && kill -0 "$(basename "$f")" 2>/dev/null && [[ "$(cat "$f")" == $1 ]] && return 0 # $1 may be a glob
  done
  return 1
}

# fetch <endpoint> <outfile> [paginated]: any failure returns 1 so the caller can skip this PR only.
fetch() {
  if [ "${3:-}" = paginated ]; then
    gh api --paginate "$1" 2>>"$STATE_DIR/polls.log" | jq -s 'add // []' >"$2" && [ -s "$2" ]
  else
    gh api "$1" >"$2" 2>>"$STATE_DIR/polls.log" && [ -s "$2" ]
  fi
}

# Remember "evaluated, nothing to do" per (mode, PR, updated_at) so quiet PRs cost no API calls.
# Own PRs are looked at again after 10 minutes anyway: when the base branch moves, a new merge
# conflict appears without the PR's updated_at changing.
RECHECK_OWN=600
settle() { printf '%s\t%s\t%s\n' "$seen_key" "$updated" "$(date +%s)" >>"$SEEN"; }
settled() {
  awk -F'\t' -v k="$seen_key" -v u="$updated" -v own="$1" -v now="$(date +%s)" -v age="$RECHECK_OWN" '
    $1 == k && $2 == u && (own != "author" || now - ($3 + 0) < age) {found = 1} END {exit !found}' "$SEEN"
}

# job.sh writes claude_limited (the reset epoch) when claude reports a spent session/usage/spend limit.
limited=""
if limit_active; then
  limited=1; log "claude limit active (until $(date -r "$(cat "$STATE_DIR/claude_limited")" 2>/dev/null || echo "30 minutes after it was hit")), not starting jobs"
fi

clear_settle() { # forget when this PR's settle wait began (uses process_item's seen_key)
  [ -f "$STATE_DIR/settle-first.tsv" ] || return 0
  awk -F'\t' -v k="$seen_key" '$1 != k' "$STATE_DIR/settle-first.tsv" >"$tmp/settle.new" && cat "$tmp/settle.new" >"$STATE_DIR/settle-first.tsv"
}
process_item() {
  local item=$1 repo n reason ev key file thread
  repo=$(jq -r .repo <<<"$item") n=$(jq -r .number <<<"$item") reason=$(jq -r .reason <<<"$item")
  local seen_key="$mode|$repo#$n" updated
  updated=$(jq -r .updated_at <<<"$item")
  if settled "$reason"; then return 0; fi # nothing new since we last settled it
  if [ "$mode" = live ] && [[ "$updated" < "$live_since" || "$updated" == "$live_since" ]]; then
    log "skip $repo#$n: predates going live (use /pr-autopilot:replay to include it)"; settle; return 0
  fi
  fetch "repos/$repo/pulls/$n" "$tmp/pr" &&
    fetch "repos/$repo/pulls/$n/reviews" "$tmp/reviews" paginated &&
    fetch "repos/$repo/pulls/$n/comments" "$tmp/comments" paginated &&
    fetch "repos/$repo/issues/$n/comments" "$tmp/issue" paginated ||
    { log "ERROR $repo#$n: could not fetch PR data, will retry next poll"; return 1; }
  # CI results (GitHub check runs) only matter on the user's own PRs.
  echo '{"check_runs": []}' >"$tmp/checks"; echo '[]' >"$tmp/threads"
  # Unresolved review threads only matter on the user's own PRs too (a feedback fix).
  if [ "$(jq -r .user.login "$tmp/pr")" = "$me" ] && ! review_threads "$repo" "$n" >"$tmp/threads" 2>>"$STATE_DIR/polls.log"; then
    log "ERROR $repo#$n: could not fetch review threads, will retry next poll"; return 1
  fi
  if [ "$(jq -r .user.login "$tmp/pr")" = "$me" ]; then
    fetch "repos/$repo/commits/$(jq -r .head.sha "$tmp/pr")/check-runs?per_page=100" "$tmp/checks" ||
      { log "ERROR $repo#$n: could not fetch check runs, will retry next poll"; return 1; }
  fi
  ev=$(jq -n -c -f "$DIR/classify.jq" --arg me "$me" --arg reason "$reason" --arg repo "$repo" \
    --argjson via_search "$(jq -r .via_search <<<"$item")" "${flags[@]}" --slurpfile pr "$tmp/pr" --slurpfile reviews "$tmp/reviews" \
    --slurpfile comments "$tmp/comments" --slurpfile issue "$tmp/issue" --slurpfile checks "$tmp/checks" --slurpfile threads "$tmp/threads") ||
    { log "ERROR $repo#$n: classification failed"; return 1; }
  # What failed.tsv pruning below may keep for this PR: only the keys of its current state. A skip
  # (draft, nothing to address) says nothing about a failure, except closed or merged.
  if [ -z "$(jq -r '.skip // ""' <<<"$ev")" ] || [ "$(jq -r .skip <<<"$ev")" = "closed or merged" ]; then
    echo "$mode|$(tr A-Z a-z <<<"$repo")|$n" >>"$tmp/evaluated"
    jq -r --arg m "$mode" '$m + "|" + .key, ((.steps // [])[] | $m + "|" + .key)' <<<"$ev" >>"$tmp/curkeys"
  fi
  [ "$(jq -r .untrusted <<<"$ev")" = 0 ] ||
    log "$repo#$n: ignoring $(jq -r .untrusted <<<"$ev") comment(s)/review(s) from untrusted authors (not owner/member/collaborator, not in trusted_commenters)"
  if [ -n "$(jq -r '.skip // ""' <<<"$ev")" ]; then
    clear_settle # nothing pending any more: the next trigger starts a new settle wait
    log "skip $repo#$n: $(jq -r .skip <<<"$ev")"
    # Too large to review: tell the owner once per head (size-skipped.tsv), like ci-gave-up.tsv.
    if [ "$(jq -r '.nosize // false' <<<"$ev")" = true ]; then
      local sk="$mode|$repo#$n|$(jq -r .head <<<"$ev")"
      if ! grep -qxF "$sk" "$STATE_DIR/size-skipped.tsv" 2>/dev/null; then
        echo "$sk" >>"$STATE_DIR/size-skipped.tsv"
        report "$(jq -r .url <<<"$ev")
PR #$n ($(jq -r .title <<<"$ev")): skipped review, GitHub gave no size (review_max_changed_lines is set)."
      fi
    elif [ "$(jq -r '.lines // ""' <<<"$ev")" != "" ]; then
      local sk="$mode|$repo#$n|$(jq -r .head <<<"$ev")"
      if ! grep -qxF "$sk" "$STATE_DIR/size-skipped.tsv" 2>/dev/null; then
        echo "$sk" >>"$STATE_DIR/size-skipped.tsv"
        report "$(jq -r .url <<<"$ev")
PR #$n ($(jq -r .title <<<"$ev")): skipped review, $(jq -r .lines <<<"$ev") changed lines is over your $(cfgd review_max_changed_lines 0)-line limit (review_max_changed_lines)."
      fi
    fi
    settle; return 0
  fi
  key="$mode|$(jq -r .key <<<"$ev")"
  # notify mode: tell the user once per event (its key goes into handled.tsv like a finished job), act on nothing.
  notify_only() { # notify_only <event json> <what happened>
    echo "$mode|$(jq -r .key <<<"$1")" >>"$HANDLED"
    report "$(jq -r .url <<<"$1")
PR #$n ($(jq -r .title <<<"$1")): $2 (notify only: nothing was posted, fixed or pushed)"
  }
  if [ "$rmode" = notify ] && [ "$(jq -r .kind <<<"$ev")" = review ] && ! grep -qxF "$key" "$HANDLED"; then
    notify_only "$ev" "$(jq -r .who <<<"$ev") asked for your review"; settle; return 0
  fi
  # Own PRs carry ordered steps (feedback, then conflict, then CI): run the first not handled yet.
  local st next=""
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    grep -qxF "$mode|$(jq -r .key <<<"$st")" "$HANDLED" && continue
    if [ "$mmode" = notify ] && [ "$(jq -r .kind <<<"$st")" = fix ]; then
      notify_only "$(jq -c --argjson s "$st" '. + $s' <<<"$ev")" "new review feedback from $(jq -r .who <<<"$st")"; continue
    fi
    next=$st; break
  done < <(jq -c '(.steps // [])[]' <<<"$ev")
  if [ -n "$next" ]; then
    ev=$(jq -c --argjson s "$next" '. + $s' <<<"$ev")
    key="$mode|$(jq -r .key <<<"$ev")"
  fi
  # At most MAX_CI_FIXES CI-fix jobs per PR: past that a red build needs the user, and saying so
  # once beats pushing guesses forever.
  if [ "$(jq -r .kind <<<"$ev")" = cifix ] &&
    [ "$(grep -c "^$mode|cifix|$repo|$n|" "$HANDLED")" -ge "$MAX_CI_FIXES" ]; then
    log "skip $repo#$n: CI still failing after $MAX_CI_FIXES fix attempts"
    if ! grep -qxF "$mode|$repo#$n" "$STATE_DIR/ci-gave-up.tsv" 2>/dev/null; then
      echo "$mode|$repo#$n" >>"$STATE_DIR/ci-gave-up.tsv"
      report "$(jq -r .url <<<"$ev")
PR #$n ($(jq -r .title <<<"$ev")): CI is still failing after $MAX_CI_FIXES fix attempts. I stopped; this one needs you."
    fi
    settle; return 0
  fi
  if [ "$(jq -r .kind <<<"$ev")" = fix ] && ! grep -qxF "$key" "$HANDLED"; then
    local nh np gk
    read -r nh np < <(awk -F'\t' -v k="$mode|$repo|$n" -v h="$(jq -r .head <<<"$ev")" \
      '$1 == k {p++; if ($2 == h) c++} END {print c + 0, p + 0}' "$STATE_DIR/fixes.tsv" 2>/dev/null || echo "0 0")
    if [ "${nh:-0}" -ge "$MAX_FIX_HEAD" ] || [ "${np:-0}" -ge "$MAX_FIX_PR" ]; then
      log "skip $repo#$n: feedback fix cap reached ($nh on this head, max $MAX_FIX_HEAD; $np on the PR, max $MAX_FIX_PR)"
      gk="$mode|$repo#$n|$([ "${np:-0}" -ge "$MAX_FIX_PR" ] && echo pr || jq -r .head <<<"$ev")"
      if ! grep -qxF "$gk" "$STATE_DIR/fix-gave-up.tsv" 2>/dev/null; then
        echo "$gk" >>"$STATE_DIR/fix-gave-up.tsv"
        report "$(jq -r .url <<<"$ev")
PR #$n ($(jq -r .title <<<"$ev")): new review feedback keeps coming after $np feedback fixes ($nh on this commit). I stopped (max_feedback_fixes); this one needs you."
      fi
      settle; return 0
    fi
  fi
  if grep -qxF "$key" "$HANDLED"; then log "already handled $key"; settle; return 0; fi
  if key_running "$key"; then log "already running $key"; return 0; fi
  # One job per PR at a time: a trigger that arrives while one runs (a new comment, a conflict) waits for
  # the next poll, so it is never lost and its job sees the pushed head instead of racing it with a second push.
  if key_running "$mode|*|$repo|$n|*"; then log "a job for $repo#$n is running, $key waits"; return 0; fi
  local nfail last
  nfail=$(awk -F'\t' -v k="$key" '$2 == k' "$FAILED" | wc -l | tr -d ' ')
  last=$(awk -F'\t' -v k="$key" '$2 == k {t = $1} END {print t + 0}' "$FAILED")
  if [ "$nfail" -ge "$MAX_ATTEMPTS" ]; then log "gave up on $key after $nfail failures"; settle; return 0; fi
  if [ "$nfail" -gt 0 ] && [ $(($(date +%s) - last)) -lt "$RETRY_AFTER" ]; then
    log "backing off $key ($nfail failures)"; return 0
  fi
  # Settle: a job that pushes starts only once the PR has been quiet for fix_settle_seconds (its updated_at
  # moves on every comment), so a burst of review and bot comments lands in one job and one push.
  # The wait ends at most settle_max_s after the poller FIRST deferred this PR (settle-first.tsv), so a PR
  # with a steady stream of comments still gets its job; it then takes every trigger pending at that moment.
  if [ "$(jq -r .kind <<<"$ev")" != review ]; then
    local quiet first now
    now=$(date +%s)
    quiet=$((now - $(jq -n -r --arg u "$updated" '$u | fromdateiso8601' 2>/dev/null || echo 0)))
    if [ "$settle_s" -gt 0 ] && [ "$quiet" -lt "$settle_s" ]; then
      first=$(awk -F'\t' -v k="$seen_key" '$1 == k {print $2}' "$STATE_DIR/settle-first.tsv" 2>/dev/null | head -1)
      if [ -z "$first" ]; then first=$now; printf '%s\t%s\n' "$seen_key" "$now" >>"$STATE_DIR/settle-first.tsv"; fi
      if [ $((now - first)) -lt "$settle_max_s" ]; then
        log "settling $key: PR active ${quiet}s ago, waiting for ${settle_s}s of quiet (fix_settle_seconds, at most ${settle_max_s}s)"; return 0
      fi
      log "settle cap reached for $key after $((now - first))s (fix_settle_max_seconds), starting now"
    fi
  fi
  if [ -n "$limited" ]; then return 0; fi
  if [ "$(running)" -ge "$max" ]; then log "at max_parallel=$max, deferring $repo#$n"; return 0; fi

  file="$STATE_DIR/events/$(date +%Y%m%dT%H%M%S)-${repo//\//_}-$n.json"
  thread=$(jq -r .thread <<<"$item")
  jq -c --argjson dry "$dry" --arg thread "$thread" --arg reason "$reason" --argjson attempt "$nfail" \
    --argjson walk "$([ "$rmode" = walk ] && echo true || echo false)" \
    '. + {dry_run: $dry, thread: $thread, reason: $reason, attempt: $attempt, walk: $walk}' <<<"$ev" >"$file"
  nohup "$JOB" "$file" >/dev/null 2>&1 </dev/null &
  echo "$key" >"$STATE_DIR/running/$!"
  clear_settle
  log "started job for $key (pid $!)"
}

while IFS= read -r item; do
  is_paused && { log "paused mid-poll, not starting more jobs"; break; }
  process_item "$item" || true
done <"$tmp/items"
# Prune failed.tsv so it lists only active failures: drop entries older than FAIL_KEEP, and entries of a
# PR evaluated this poll whose key is not current (new head, new review round, resolved) or that closed.
# A PR merely absent from this poll's list keeps its entries, or a flaky search would reset the 3-attempt cap. Skipped when a job runs: it may append to the file.
if [ -s "$FAILED" ] && [ "$(running)" -eq 0 ]; then
  touch "$tmp/evaluated" "$tmp/curkeys"
  # Keys go in via files: BSD awk rejects newlines in -v values.
  awk -F'\t' -v now="$(date +%s)" -v keep="$FAIL_KEEP" -v fe="$tmp/evaluated" -v fc="$tmp/curkeys" '
    function load(file, arr,   l) { while ((getline l < file) > 0) arr[l] = 1; close(file) }
    BEGIN { load(fe, evd); load(fc, ck) }
    { split($2, f, "|"); pr = tolower(f[3]) "|" f[4]
      if (now - $1 > keep || ((f[1] "|" pr) in evd && !($2 in ck))) next
      print }' "$FAILED" >"$tmp/failed.new" && cat "$tmp/failed.new" >"$FAILED"
fi
# transient.tsv (runs not counted as attempts) only matters for a day.
if [ -s "$STATE_DIR/transient.tsv" ] && [ "$(running)" -eq 0 ]; then
  awk -F'\t' -v t="$(($(date +%s) - 86400))" '$1 > t' "$STATE_DIR/transient.tsv" >"$tmp/transient.new" &&
    cat "$tmp/transient.new" >"$STATE_DIR/transient.tsv"
fi
log "poll done ($(wc -l <"$tmp/items" | tr -d ' ') items)"
