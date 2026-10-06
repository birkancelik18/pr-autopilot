#!/usr/bin/env bash
# One job: usage job.sh <event.json> (written by poll.sh).
#
# Trust model: headless Claude only READS (the PR checkout in a throwaway worktree, plus files this
# script pre-fetched into a job dir) and WRITES files (draft.md or result.json in the job dir, edits in
# the worktree). It never talks to GitHub. This script does every GitHub write itself, after its own
# checks, and reports only what it verified on GitHub.
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"
EV=$1
g() { jq -r "$1" "$EV"; }
repo=$(g .repo) n=$(g .number) kind=$(g .kind) head=$(g .head) branch=$(g .branch) base=$(g .base)
title=$(g .title) url=$(g .url) dry=$(g .dry_run) who=$(g .who) cr=$(g '.cr // false')
thread=$(g '.thread // ""') key=$(g .key)
mode=live; [ "$dry" = true ] && mode=dry
DKEY="$mode|$key"

slug=${repo//\//_} stamp=$(date +%Y%m%dT%H%M%S)
LOG=$STATE_DIR/logs/$stamp-$slug-$n-$kind.log
JOB=$STATE_DIR/jobs/$stamp-$slug-$n-$kind-$$
WT=$STATE_DIR/worktrees/$slug-$n-$kind-$$
REF=refs/pr-autopilot/$n-$$ BASEREF=refs/pr-autopilot/base-$n-$$
mkdir -p "$JOB"
echo "# $stamp $kind $repo#$n head=$head dry_run=$dry" >"$LOG"
clone=$(jq -r --arg r "$repo" '.repos | to_entries[] | select(.key | ascii_downcase == ($r | ascii_downcase)) | .value' "$CONFIG")

if [ "$kind" = review ]; then what="$who asked you to review it"
elif [ "$cr" = true ]; then what="$who requested changes on yours"
else what="$who commented on yours"; fi
prefix="PR #$n ($title): $what."
[ "$dry" = true ] && prefix="[DRY RUN] $prefix"

cpid="" wd="" posted=0
stop_wd() { [ -n "$wd" ] && { pkill -P "$wd" 2>/dev/null; kill "$wd" 2>/dev/null; wd=""; }; }
cleanup() {
  [ -n "$cpid" ] && kill "$cpid" 2>/dev/null
  stop_wd
  [ -d "$WT" ] && git -C "$clone" worktree remove --force "$WT" 2>/dev/null
  git -C "$clone" update-ref -d "$REF" 2>/dev/null
  git -C "$clone" update-ref -d "$BASEREF" 2>/dev/null
  rm -f "$STATE_DIR/running/$$"
}
trap cleanup EXIT
# Pause or a signal stops the job without counting a failure; the notification stays unread, so the
# next poll after /pr-autopilot:resume starts it again.
trap 'echo "stopped (pause or signal)" >>"$LOG"; log "job $repo#$n stopped, will rerun after resume"; exit 143' TERM INT
abort_if_paused() { is_paused && { echo "paused, aborting before any write" >>"$LOG"; log "job $repo#$n aborted by pause"; exit 143; }; }

fail() { # fail <message>: loud report; retried by the poller (max 3) unless we already wrote to GitHub
  local nf
  echo "FAILED: $1" >>"$LOG"
  if [ "$posted" = 1 ]; then
    echo "$DKEY" >>"$STATE_DIR/handled.tsv" # a repeat could double-post
    report "$prefix PARTLY DONE, then FAILED: $1. Not retried automatically, check the PR. Log: $LOG. $url"
  else
    printf '%s\t%s\n' "$(date +%s)" "$DKEY" >>"$STATE_DIR/failed.tsv"
    nf=$(awk -F'\t' -v k="$DKEY" '$2 == k' "$STATE_DIR/failed.tsv" | wc -l | tr -d ' ')
    report "$prefix FAILED (attempt $nf of 3$([ "$nf" -ge 3 ] && echo ", giving up")): $1. Log: $LOG. $url"
  fi
  exit 1
}
succeed() { # succeed <outcome verified on GitHub>
  echo "$DKEY" >>"$STATE_DIR/handled.tsv"
  if [ "$mode" = live ] && [ -n "$thread" ]; then
    gh api -X PATCH "notifications/threads/$thread" >/dev/null 2>&1 || log "could not mark $thread read"
  fi
  report "$prefix $1 $url"
  exit 0
}
skip_quietly() { echo "$1" >>"$LOG"; log "$repo#$n: $1"; exit 0; } # poll re-evaluates with fresh data

check_head() { # PR still open, ready, and at the head we worked on
  local cur
  cur=$(gh api "repos/$repo/pulls/$n" --jq '[.state, (.draft | tostring), .head.sha] | join(" ")' 2>>"$LOG") ||
    fail "cannot re-read the PR from GitHub"
  [ "$cur" = "open false $head" ] || skip_quietly "PR changed while the job ran ($cur), nothing written"
}
gh_get() { gh api "$@" 2>>"$LOG"; }

# --- preflight
me=$(gh api user --jq .login 2>>"$LOG"); [ -n "$me" ] || fail "gh api user failed (not logged in or offline)"
[ -d "$clone/.git" ] || [ -f "$clone/.git" ] || fail "clone path '$clone' is not a git checkout (fix config.json)"
abort_if_paused

# --- pre-fetch everything the model may read into the job dir (all of it is untrusted data)
gh_get "repos/$repo/pulls/$n" >"$JOB/pr.json" || fail "fetch PR failed"
[ "$(jq -r .head.sha "$JOB/pr.json")" = "$head" ] || skip_quietly "head moved before start"
gh pr diff "$n" --repo "$repo" >"$JOB/diff.patch" 2>>"$LOG" || fail "fetch diff failed"
for ep in reviews comments issue-comments; do
  case $ep in
    reviews) path="repos/$repo/pulls/$n/reviews" ;;
    comments) path="repos/$repo/pulls/$n/comments" ;;
    issue-comments) path="repos/$repo/issues/$n/comments" ;;
  esac
  gh api --paginate "$path" 2>>"$LOG" | jq -s 'add // []' >"$JOB/$ep.json" || fail "fetch $ep failed"
  [ -s "$JOB/$ep.json" ] || fail "fetch $ep returned nothing"
done

# --- checkout of the PR head without the repo's agent config (it is untrusted)
git -C "$clone" fetch -q origin "+pull/$n/head:$REF" "+refs/heads/$base:$BASEREF" >>"$LOG" 2>&1 ||
  fail "git fetch of PR head/base failed"
[ "$(git -C "$clone" rev-parse "$REF")" = "$head" ] || skip_quietly "head moved before checkout"
git -C "$clone" worktree add -q --detach --no-checkout "$WT" "$head" >>"$LOG" 2>&1 || fail "git worktree add failed"
git -C "$WT" sparse-checkout set --no-cone '/*' '!CLAUDE.md' '!CLAUDE.local.md' '!AGENTS.md' \
  '!.claude/' '!.mcp.json' >>"$LOG" 2>&1 || fail "sparse-checkout failed"
git -C "$WT" checkout -q --detach "$head" >>"$LOG" 2>&1 || fail "git checkout failed"
# The BASE branch's conventions, as plain read-only data (renamed so nothing loads them as config).
mkdir -p "$JOB/conventions"
for f in AGENTS.md CLAUDE.md; do
  git -C "$clone" show "$BASEREF:$f" >"$JOB/conventions/$f.txt" 2>/dev/null || rm -f "$JOB/conventions/$f.txt"
done
git -C "$clone" ls-tree -r --name-only "$BASEREF" -- .claude/rules 2>/dev/null | while IFS= read -r f; do
  git -C "$clone" show "$BASEREF:$f" >"$JOB/conventions/${f//\//__}.txt"
done

# --- tools. Reads (Read/Grep/Glob) need no rule: dontAsk allows them only inside the working
# directories, which are the worktree (cwd) and the job dir (--add-dir). Everything else is denied.
deny=("Bash(gh *)" "Bash(git *)" "Bash(curl *)" "Bash(wget *)" "Bash(ssh *)" "Bash(scp *)"
  "Read(~/.config/gh/**)" "Read(~/.config/pr-autopilot/**)" "Read(~/.ssh/**)" "Read(~/.aws/**)"
  "Edit(/$WT/.git)" "Edit(/$WT/.git/**)")
if [ "$kind" = review ]; then
  allow=(Agent "Edit(/$JOB/draft.md)")
  skill=review-pr
else
  allow=("Edit(/$WT/**)" "Edit(/$JOB/result.json)")
  while IFS= read -r t; do allow+=("Bash($t)"); done < <(jq -r '(.test_commands // ["npm run lint*",
    "npm run test*", "npm test*", "npm run typecheck*", "npx vitest*", "npx eslint*", "pytest*",
    "uv run pytest*", "uv run ruff*", "ruff *", "mypy*", "make test*", "make lint*", "go test*",
    "cargo test*"])[]' "$CONFIG")
  skill=address-review
fi
join() { local IFS=,; echo "$*"; }

prompt="/pr-autopilot:$skill job_dir=$JOB me=$me"
tmo=$(cfgd job_timeout_minutes 30)
cd "$WT" || fail "cannot enter worktree"
abort_if_paused
claude -p "$prompt" --plugin-dir "$PLUGIN_ROOT" --permission-mode dontAsk \
  --setting-sources "" --strict-mcp-config --settings '{"disableAllHooks":true}' \
  --add-dir "$JOB" --allowedTools "$(join "${allow[@]}")" --disallowedTools "$(join "${deny[@]}")" \
  --output-format stream-json --verbose --no-session-persistence </dev/null >"$JOB/claude.jsonl" 2>>"$LOG" &
cpid=$!
(sleep $((tmo * 60)); echo "timeout after ${tmo}m" >>"$LOG"; kill "$cpid" 2>/dev/null) 2>/dev/null &
wd=$!; disown "$wd"
wait "$cpid"; rc=$?
stop_wd; cpid=""
jq -c 'select(.type == "result")' "$JOB/claude.jsonl" 2>/dev/null | tail -1 >"$JOB/claude.json"
jq -r '.result // empty' "$JOB/claude.json" >>"$LOG" 2>/dev/null
# Per-job evidence of what actually ran: subagent (Agent tool) calls, how many in one message, turns, time, cost.
agent_calls=$(jq -s '[.[] | select(.type == "assistant" and .parent_tool_use_id == null) | .message.content[]?
  | select(.type == "tool_use" and (.name == "Agent" or .name == "Task")) | .id] | unique | length' "$JOB/claude.jsonl" 2>/dev/null || echo 0)
agent_parallel=$(jq -s '[.[] | select(.type == "assistant" and .parent_tool_use_id == null)
  | {m: .message.id, c: [.message.content[]? | select(.type == "tool_use" and (.name == "Agent" or .name == "Task")) | .id]}]
  | group_by(.m) | map(map(.c[]) | unique | length) | max // 0' "$JOB/claude.jsonl" 2>/dev/null || echo 0)
echo "stats: agent_calls=${agent_calls:-0} max_agents_in_one_message=${agent_parallel:-0} $(jq -r '"num_turns=\(.num_turns) duration_ms=\(.duration_ms) cost_usd=\(.total_cost_usd)"' "$JOB/claude.json" 2>/dev/null)" >>"$LOG"
echo "permission denials: $(jq -r '.permission_denials | length' "$JOB/claude.json" 2>/dev/null)" >>"$LOG"
[ "$rc" -eq 0 ] || fail "claude exited with status $rc (143 or 137 usually means the timeout)"
[ "$(jq -r '.is_error // false' "$JOB/claude.json" 2>/dev/null)" = false ] ||
  fail "claude reported an error: $(jq -r '.result // "?"' "$JOB/claude.json" | head -c 200)"

# =============================== review: post the draft ===============================
finish_review() {
  [ "${agent_calls:-0}" -ge 3 ] ||
    fail "review needs three parallel passes but only ${agent_calls:-0} subagent call(s) ran (max in one message: ${agent_parallel:-0})"
  [ -s "$JOB/draft.md" ] || fail "the model wrote no draft.md"
  local verdict body_words why
  verdict=$(head -1 "$JOB/draft.md" | tr -d '\r')
  case $verdict in
    'VERDICT: APPROVE') event=APPROVE; state=APPROVED ;;
    'VERDICT: REQUEST_CHANGES') event=REQUEST_CHANGES; state=CHANGES_REQUESTED ;;
    *) fail "draft.md first line must be 'VERDICT: APPROVE' or 'VERDICT: REQUEST_CHANGES', got '$verdict'" ;;
  esac
  tail -n +2 "$JOB/draft.md" | sed '/./,$!d' >"$JOB/body.md"
  body_words=$(wc -w <"$JOB/body.md" | tr -d ' ')
  [ "$body_words" -gt 0 ] || fail "draft.md has no body"
  [ "$body_words" -le 150 ] || fail "draft body is $body_words words, limit is 150"
  why=$(head -1 "$JOB/body.md" | cut -c1-160)

  check_head
  local already
  already=$(gh_get --paginate "repos/$repo/pulls/$n/reviews" | jq -s --arg me "$me" --arg h "$head" \
    '[add[] | select(.user.login == $me and .commit_id == $h and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))] | length') ||
    fail "cannot list existing reviews"
  [ "$already" = 0 ] || succeed "I did not post: I already reviewed this commit."
  if [ "$dry" = true ]; then
    succeed "I would have posted $event: $why (nothing was posted)."
  fi
  abort_if_paused
  posted=1
  local resp rid got
  resp=$(gh api -X POST "repos/$repo/pulls/$n/reviews" -f commit_id="$head" -f event="$event" \
    -F body=@"$JOB/body.md" 2>>"$LOG") || fail "posting the review failed"
  rid=$(jq -r '.id // empty' <<<"$resp")
  [ -n "$rid" ] || fail "review post returned no id"
  got=$(gh_get "repos/$repo/pulls/$n/reviews/$rid" --jq '[.user.login, .commit_id, .state] | join(" ")') ||
    fail "could not read the review back"
  [ "$got" = "$me $head $state" ] || fail "review read back as '$got', expected '$me $head $state'"
  succeed "I posted $event (verified on GitHub, review $rid, commit ${head:0:7}): $why"
}

# =============================== fix: commit, push, reply, re-request ===============================
finish_fix() {
  local r=$JOB/result.json
  [ -s "$r" ] || fail "the model wrote no result.json"
  jq -e --slurpfile cm "$JOB/comments.json" '
    (.summary | type == "string") and (.commit_message // "x" | type == "string")
    and (.re_request | type == "array" and all(type == "string"))
    and (.replies | type == "array" and all(
      (.body | type == "string" and length > 0 and length < 3000)
      and (.in_reply_to == null or (.in_reply_to as $i | $cm[0] | any(.id == $i)))))' "$r" >/dev/null ||
    fail "result.json is malformed or replies to a comment id that does not exist"

  local dirty changed summary msg newsha
  dirty=$(git -C "$WT" status --porcelain | wc -l | tr -d ' ')
  summary=$(jq -r '.summary' "$r" | cut -c1-200)
  nreplies=$(jq '.replies | length' "$r")
  check_head
  if [ "$dry" = true ]; then
    local lg; lg=$(jq -r '.re_request | map("@" + .) | join(", ")' "$r")
    succeed "I would have $([ "$dirty" -gt 0 ] && echo "fixed: $summary ($dirty files), pushed, ")replied on $nreplies thread(s)$([ -n "$lg" ] && echo ", re-requested review from $lg") (nothing was pushed or posted)."
  fi
  abort_if_paused
  newsha=$head
  if [ "$dirty" -gt 0 ]; then
    msg=$(jq -r '.commit_message // "Address review feedback"' "$r" | head -c 300)
    [ -n "$msg" ] || msg="Address review feedback"
    git -C "$WT" add -A >>"$LOG" 2>&1 || fail "git add failed"
    git -C "$WT" -c core.hooksPath=/dev/null commit -q -m "$msg" >>"$LOG" 2>&1 || fail "git commit failed"
    newsha=$(git -C "$WT" rev-parse HEAD)
    posted=1
    git -C "$WT" -c core.hooksPath=/dev/null push -q --no-verify origin "HEAD:refs/heads/$branch" >>"$LOG" 2>&1 ||
      { posted=0; fail "git push was rejected (not forced, remote probably moved)"; }
    local i seen=""
    for i in 1 2 3 4 5; do
      seen=$(gh_get "repos/$repo/pulls/$n" --jq .head.sha); [ "$seen" = "$newsha" ] && break; sleep 2
    done
    [ "$seen" = "$newsha" ] || fail "pushed ${newsha:0:7} but GitHub shows head ${seen:0:7}"
  fi

  local short=${newsha:0:7} errs="" nposted=0 idx id body resp
  for idx in $(seq 0 $((nreplies - 1))); do
    id=$(jq -r ".replies[$idx].in_reply_to // empty" "$r")
    body=$(jq -r --arg s "$short" ".replies[$idx].body | gsub(\"\\\\{\\\\{sha\\\\}\\\\}\"; \$s)" "$r")
    posted=1
    if [ -n "$id" ]; then resp=$(gh api "repos/$repo/pulls/$n/comments/$id/replies" -f body="$body" 2>>"$LOG")
    else resp=$(gh api "repos/$repo/issues/$n/comments" -f body="$body" 2>>"$LOG"); fi
    if [ -n "$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)" ]; then nposted=$((nposted + 1))
    else errs="$errs reply $((idx + 1)) failed;"; fi
  done

  local want args=() l missing=""
  want=$(jq -r --slurpfile rv "$JOB/reviews.json" --arg me "$me" '[.re_request[]
    | select(. != $me and (endswith("[bot]") | not))
    | select(. as $l | $rv[0] | any(.user.login == $l))] | unique | .[]' "$r")
  if [ -n "$want" ]; then
    for l in $want; do args+=(-f "reviewers[]=$l"); done
    posted=1
    gh api -X POST "repos/$repo/pulls/$n/requested_reviewers" "${args[@]}" >/dev/null 2>>"$LOG" ||
      errs="$errs re-request failed;"
    local reqd; reqd=$(gh_get "repos/$repo/pulls/$n" --jq '[.requested_reviewers[].login] | join(" ")')
    for l in $want; do case " $reqd " in *" $l "*) ;; *) missing="$missing $l" ;; esac; done
    [ -z "$missing" ] || errs="$errs not shown as requested on GitHub:$missing;"
  fi
  [ -z "$errs" ] || fail "after the push:$errs"
  local out
  if [ "$newsha" != "$head" ]; then out="I fixed $summary, pushed $short"; else out="I fixed nothing"; fi
  [ "$nposted" -gt 0 ] && out="$out, replied on $nposted thread(s)"
  [ -n "$want" ] && out="$out, re-requested review from $(for l in $want; do printf '@%s ' "$l"; done | sed 's/ $//; s/ /, /g')"
  succeed "$out (verified on GitHub)."
}

if [ "$kind" = review ]; then finish_review; else finish_fix; fi
