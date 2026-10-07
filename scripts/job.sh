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
title=$(g .title) url=$(g .url) who=$(g .who) cr=$(g '.cr // false')
thread=$(g '.thread // ""') key=$(g .key)
# Fail closed: live only when the event says dry_run is exactly false (missing or odd means dry).
dry=$(jq -r 'if .dry_run == false then "false" else "true" end' "$EV")
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
elif [ "$kind" = conflict ]; then what="yours has merge conflicts with $base"
elif [ "$kind" = cifix ]; then what="CI failed on yours"
elif [ "$cr" = true ]; then what="$who requested changes on yours"
else what="$who commented on yours"; fi
# The PR link leads the notification: a click cannot open it, so it has to be readable.
prefix="PR #$n ($title): $what."
[ "$dry" = true ] && prefix="[DRY RUN] $prefix"
prefix="$url
$prefix"

cpid="" wd="" posted=0
stop_wd() { [ -n "$wd" ] && { pkill -P "$wd" 2>/dev/null; kill "$wd" 2>/dev/null; wd=""; }; }
cleanup() {
  [ -n "$cpid" ] && { kill -TERM -- "-$cpid" 2>/dev/null; kill "$cpid" 2>/dev/null; }
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
    report "$prefix PARTLY DONE, then FAILED: $1. Not retried automatically, check the PR. Log: $LOG."
  else
    printf '%s\t%s\n' "$(date +%s)" "$DKEY" >>"$STATE_DIR/failed.tsv"
    nf=$(awk -F'\t' -v k="$DKEY" '$2 == k' "$STATE_DIR/failed.tsv" | wc -l | tr -d ' ')
    report "$prefix FAILED (attempt $nf of 3$([ "$nf" -ge 3 ] && echo ", giving up")): $1. Log: $LOG."
  fi
  exit 1
}
succeed() { # succeed <outcome verified on GitHub>
  echo "$DKEY" >>"$STATE_DIR/handled.tsv"
  if [ "$mode" = live ] && [ -n "$thread" ]; then
    gh api -X PATCH "notifications/threads/$thread" >/dev/null 2>&1 || log "could not mark $thread read"
  fi
  report "$prefix $1"
  exit 0
}
# The PR changed under us: nothing was written and the poller starts over with fresh data. If that
# keeps happening, say so instead of looping silently.
skip_quietly() {
  echo "$1" >>"$LOG"; log "$repo#$n: $1"
  echo "$DKEY" >>"$STATE_DIR/quiet.tsv"
  [ "$(grep -cxF "$DKEY" "$STATE_DIR/quiet.tsv")" -lt 3 ] ||
    report "$prefix Skipped $(grep -cxF "$DKEY" "$STATE_DIR/quiet.tsv") times because the PR keeps changing ($1)."
  exit 0
}
live_now() { # config must still say dry_run is exactly false at the moment of any write
  [ "$dry" = true ] || [ "$(jq -r 'if .dry_run == false then "false" else "true" end' "$CONFIG" 2>/dev/null)" = false ] ||
    skip_quietly "config is no longer live, nothing written"
}

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
ourl=$(git -C "$clone" config --get remote.origin.url | tr 'A-Z' 'a-z'); rl=$(tr 'A-Z' 'a-z' <<<"$repo")
case $ourl in
  *[:/]"$rl" | *[:/]"$rl".git) ;;
  *) fail "the clone's origin ($ourl) does not point at $repo, refusing to fetch or push" ;;
esac
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
# Named rules__<file>.txt: a leading dot would hide them from the model's file listing.
git -C "$clone" ls-tree -r --name-only "$BASEREF" -- .claude/rules 2>/dev/null | while IFS= read -r f; do
  rel=${f#.claude/}
  git -C "$clone" show "$BASEREF:$f" >"$JOB/conventions/${rel//\//__}.txt"
done
# The user's own review skills (config review_skills): one extra parallel pass each. They are the
# user's text, not the PR's, so they are trusted instructions for that pass; copied into the job
# dir because the model may not read outside it.
npasses=3
if [ "$kind" = review ]; then
  mkdir -p "$JOB/review-skills"
  i=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p=${p/#\~/$HOME}
    [ -f "$p" ] && [ -r "$p" ] || fail "review_skills entry '$p' is not a readable file (fix config.json)"
    i=$((i + 1))
    name=$(basename "$p"); [ "$name" = SKILL.md ] && name=$(basename "$(dirname "$p")").md
    cp "$p" "$JOB/review-skills/$i-$name" || fail "could not copy review skill '$p'"
  done < <(jq -r '(.review_skills // [])[]' "$CONFIG")
  npasses=$((3 + i))
fi

# --- merge conflict: merge the base into the PR head here; the model resolves only what conflicts.
# Agent config, binary and deleted-on-one-side files are never handed to the model: the user gets them.
# --no-commit runs no git hooks; the commit in finish_conflict switches them off like the fix path.
skip_model=""
if [ "$kind" = conflict ]; then
  git -C "$WT" merge --no-ff --no-commit "$BASEREF" >>"$LOG" 2>&1; mrc=$?
  git -C "$WT" diff --name-only --diff-filter=U >"$JOB/conflicts.txt"
  if [ ! -s "$JOB/conflicts.txt" ]; then
    [ "$mrc" -eq 0 ] || fail "git merge of $base failed without conflicts (see log)"
    skip_model=1 # merged cleanly here; nothing for the model to resolve
  else
    why=""
    while IFS= read -r f; do
      case "/$f" in
        */CLAUDE.md | */CLAUDE.local.md | */AGENTS.md | */.mcp.json | */.claude/*) why="$why $f (agent config)" ;;
        *) if [ ! -f "$WT/$f" ]; then why="$why $f (deleted on one side)"
           elif ! LC_ALL=C grep -qI '' "$WT/$f"; then why="$why $f (binary)"; fi ;;
      esac
    done <"$JOB/conflicts.txt"
    if [ -n "$why" ]; then
      git -C "$WT" merge --abort >>"$LOG" 2>&1
      succeed "I did not resolve the merge conflicts: these need you:$why. Please merge $base in by hand."
    fi
  fi
fi

# --- failing CI: hand the model the failing checks and the tail of each GitHub Actions job log
# (untrusted data, like the rest of the PR). The model only edits files; CI verifies the fix.
if [ "$kind" = cifix ]; then
  mkdir -p "$JOB/ci"
  gh_get "repos/$repo/commits/$head/check-runs?per_page=100" | jq '[.check_runs[]
    | select((.conclusion // "") | IN("failure", "timed_out"))
    | {id, name, conclusion, details_url, app: (.app.slug // ""), title: (.output.title // ""),
       summary: ((.output.summary // "") | .[0:4000]), text: ((.output.text // "") | .[0:4000])}]' \
    >"$JOB/ci/failed.json" || fail "could not fetch the failing checks"
  [ "$(jq length "$JOB/ci/failed.json")" -gt 0 ] || skip_quietly "no failing check on this commit any more"
  ci_i=0
  while IFS=$'\t' read -r ci_id ci_name ci_app; do
    ci_i=$((ci_i + 1))
    [ "$ci_app" = github-actions ] || continue
    gh api "repos/$repo/actions/jobs/$ci_id/logs" 2>>"$LOG" | tail -n 400 \
      >"$JOB/ci/$ci_i-$(printf '%s' "$ci_name" | tr -c 'A-Za-z0-9._-' _ | cut -c1-60).log" ||
      echo "could not fetch the log of $ci_name" >>"$LOG"
  done < <(jq -r '.[] | [.id, .name, .app] | @tsv' "$JOB/ci/failed.json")
fi

# --- tools. Reads (Read/Grep/Glob) need no rule: dontAsk allows them only inside the working
# directories, which are the worktree (cwd) and the job dir (--add-dir). Everything else is denied.
deny=("Bash(gh *)" "Bash(git *)" "Bash(curl *)" "Bash(wget *)" "Bash(ssh *)" "Bash(scp *)"
  "Read(~/.config/gh/**)" "Read(~/.config/pr-autopilot/**)" "Read(~/.ssh/**)" "Read(~/.aws/**)"
  "Edit(/$WT/.git)" "Edit(/$WT/.git/**)")
if [ "$kind" = review ]; then
  allow=(Agent "Edit(/$JOB/draft.md)")
  skill=review-pr
elif [ "$kind" = conflict ]; then
  allow=("Edit(/$WT/**)" "Edit(/$JOB/result.json)")
  skill=resolve-conflicts
elif [ "$kind" = cifix ]; then
  allow=("Edit(/$WT/**)" "Edit(/$JOB/result.json)")
  skill=fix-ci
else
  # No Bash at all: the model only edits files. The script commits, pushes and (opt-in, sandboxed) tests.
  allow=("Edit(/$WT/**)" "Edit(/$JOB/result.json)")
  skill=address-review
fi
join() { local IFS=,; echo "$*"; }

prompt="/pr-autopilot:$skill job_dir=$JOB me=$me"
tmo=$(cfgd job_timeout_minutes 30)
cd "$WT" || fail "cannot enter worktree"
abort_if_paused
total_cost=0
# run_claude <prompt> <out.jsonl>: sets rc. Own process group so pause or the timeout kill all of it.
run_claude() {
  set -m
  claude -p "$1" --plugin-dir "$PLUGIN_ROOT" --permission-mode dontAsk \
    --setting-sources "" --strict-mcp-config --settings '{"disableAllHooks":true}' \
    --add-dir "$JOB" --allowedTools "$(join "${allow[@]}")" --disallowedTools "$(join "${deny[@]}")" \
    --output-format stream-json --verbose --no-session-persistence </dev/null >"$2" 2>>"$LOG" &
  cpid=$!
  set +m
  (sleep $((tmo * 60)); echo "timeout after ${tmo}m" >>"$LOG"; kill -TERM -- "-$cpid" 2>/dev/null; kill "$cpid" 2>/dev/null) 2>/dev/null &
  wd=$!; disown "$wd"
  wait "$cpid"; rc=$?
  stop_wd; cpid=""
  jq -c 'select(.type == "result")' "$2" 2>/dev/null | tail -1 >"$2.result"
  total_cost=$(awk -v t="$total_cost" -v c="$(jq -r '.total_cost_usd // 0' "$2.result" 2>/dev/null)" 'BEGIN {printf "%.4f", t + c}')
}
# Cost is reported, never enforced: one line in the log and a notification if over max_cost_usd_per_job.
cost_check() {
  echo "usage: total_cost_usd=$total_cost" >>"$LOG"
  local max; max=$(cfgd max_cost_usd_per_job 10)
  awk -v t="$total_cost" -v m="$max" 'BEGIN {exit !(t > m)}' &&
    report "$prefix Cost warning: this job cost about \$$total_cost, over max_cost_usd_per_job=$max (nothing was stopped). Log: $LOG"
  return 0
}
if [ -z "$skip_model" ]; then
  run_claude "$prompt" "$JOB/claude.jsonl"
  cp "$JOB/claude.jsonl.result" "$JOB/claude.json"
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

  cost_check
fi

# =============================== review: post the draft ===============================
finish_review() {
  [ "${agent_calls:-0}" -ge "$npasses" ] ||
    fail "review needs $npasses parallel passes but only ${agent_calls:-0} subagent call(s) ran (max in one message: ${agent_parallel:-0})"
  [ -s "$JOB/draft.md" ] || fail "the model wrote no draft.md"
  local verdict verdict2 body_words why
  verdict=$(head -1 "$JOB/draft.md" | tr -d '\r')
  case $verdict in
    'VERDICT: APPROVE') event=APPROVE; state=APPROVED ;;
    'VERDICT: REQUEST_CHANGES') event=REQUEST_CHANGES; state=CHANGES_REQUESTED ;;
    *) fail "draft.md first line must be 'VERDICT: APPROVE' or 'VERDICT: REQUEST_CHANGES', got '$verdict'" ;;
  esac
  tail -n +2 "$JOB/draft.md" | sed '/./,$!d' >"$JOB/body.md"
  body_words=$(wc -w <"$JOB/body.md" | tr -d ' ')
  [ "$body_words" -gt 0 ] || fail "draft.md has no body"
  if [ "$body_words" -gt 150 ]; then
    # Do not throw a whole review away over length: one cheap follow-up asks for a shorter draft.
    echo "draft is $body_words words, asking for a shorter one" >>"$LOG"
    abort_if_paused
    run_claude "SHORTEN the review draft at $JOB/draft.md to at most 140 words in the body. Keep the first line (VERDICT) exactly as it is, keep every blocker with its file:line and failure, drop nitpicks, filler and repetition first. Edit that file only. Do not review anything again. job_dir=$JOB" "$JOB/claude-shorten.jsonl"
    cost_check
    [ "$rc" -eq 0 ] || fail "claude exited with status $rc while shortening the draft"
    verdict2=$(head -1 "$JOB/draft.md" | tr -d '\r')
    [ "$verdict2" = "$verdict" ] || fail "shortening changed the VERDICT line"
    tail -n +2 "$JOB/draft.md" | sed '/./,$!d' >"$JOB/body.md"
    body_words=$(wc -w <"$JOB/body.md" | tr -d ' ')
    [ "$body_words" -gt 0 ] || fail "the shortened draft has no body"
  fi
  [ "$body_words" -le 150 ] || fail "draft body is $body_words words even after asking for a shorter one, limit is 150"
  why=$(head -1 "$JOB/body.md" | cut -c1-160)

  check_head
  local already assoc
  already=$(gh_get --paginate "repos/$repo/pulls/$n/reviews" | jq -s --arg me "$me" --arg h "$head" \
    '[add[] | select(.user.login == $me and .commit_id == $h and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))] | length') ||
    fail "cannot list existing reviews"
  [ "$already" = 0 ] || succeed "I did not post: I already reviewed this commit."
  # An APPROVE is the one thing a hostile diff would try to steer, so it is only posted automatically
  # for PRs by people in your org. For anyone else you get the draft and decide.
  assoc=$(g '.author_assoc // "NONE"')
  if [ "$event" = APPROVE ] && [ "$assoc" != OWNER ] && [ "$assoc" != MEMBER ] &&
    [ "$(cfgd auto_approve_outsiders false)" != true ]; then
    succeed "I wrote an APPROVE draft but did not post it: the PR author is $assoc, not a member of your org. Draft: $JOB/draft.md. $why"
  fi
  if [ "$dry" = true ]; then
    succeed "I would have posted $event: $why (nothing was posted)."
  fi
  live_now
  abort_if_paused
  defang <"$JOB/body.md" >"$JOB/body.safe.md"
  posted=1
  local resp rid got
  resp=$(gh api -X POST "repos/$repo/pulls/$n/reviews" -f commit_id="$head" -f event="$event" \
    -F body=@"$JOB/body.safe.md" 2>>"$LOG") || fail "posting the review failed"
  rid=$(jq -r '.id // empty' <<<"$resp")
  [ -n "$rid" ] || fail "review post returned no id"
  got=$(gh_get "repos/$repo/pulls/$n/reviews/$rid" --jq '[.user.login, .commit_id, .state] | join(" ")') ||
    fail "could not read the review back"
  [ "$got" = "$me $head $state" ] || fail "review read back as '$got', expected '$me $head $state'"
  succeed "I posted $event (verified on GitHub, review $rid, commit ${head:0:7}): $why"
}

# Opt-in only (config run_local_tests_UNSAFE: {"owner/repo": ["exact command", ...]}), never in dry-run.
# The script runs the exact configured commands itself, sandboxed (no network, writes only inside the
# checkout and tmp, secrets dirs unreadable) with a scrubbed environment. macOS only (sandbox-exec).
run_local_tests() {
  [ "$dry" = true ] && return 0
  local cmds cmd wtr jobr prof rc
  cmds=$(jq -r --arg r "$repo" '(.run_local_tests_UNSAFE // {}) | to_entries[]
    | select(.key | ascii_downcase == ($r | ascii_downcase)) | .value[]' "$CONFIG")
  [ -n "$cmds" ] || return 0
  command -v sandbox-exec >/dev/null ||
    fail "run_local_tests_UNSAFE is set but sandbox-exec is not available here; refusing to run tests unsandboxed"
  wtr=$(cd "$WT" && pwd -P); jobr=$(cd "$JOB" && pwd -P); mkdir -p "$JOB/home"
  prof="(version 1)(allow default)(deny network*)(deny file-write* (require-not (require-any (subpath \"$wtr\") (subpath \"$jobr\") (subpath \"/private/tmp\") (subpath \"/private/var/folders\") (subpath \"/dev\"))))(deny file-read* (subpath \"$HOME/.ssh\") (subpath \"$HOME/.aws\") (subpath \"$HOME/.config/gh\") (subpath \"$HOME/.config/pr-autopilot\"))"
  while IFS= read -r cmd; do
    case $cmd in
      *'*'* | npx* | *' -exec'* | *sandbox*) fail "refusing unsafe local test command '$cmd' (no globs, npx or -exec)" ;;
    esac
    echo "running sandboxed: $cmd" >>"$LOG"
    set -m
    (cd "$WT" && exec env -i PATH="$PATH" HOME="$jobr/home" TMPDIR=/private/tmp LANG=C.UTF-8 \
      sandbox-exec -p "$prof" bash -c "$cmd") >>"$LOG" 2>&1 &
    cpid=$!; set +m
    wait "$cpid"; rc=$?; cpid=""
    [ "$rc" -eq 0 ] || fail "local test command '$cmd' failed (exit $rc), nothing committed"
  done <<<"$cmds"
}

# =============================== fix: commit, push, reply, re-request ===============================
finish_fix() {
  local r=$JOB/result.json
  [ -s "$r" ] || fail "the model wrote no result.json"
  jq -e --slurpfile cm "$JOB/comments.json" '
    (.summary | type == "string") and (.commit_message // "x" | type == "string")
    and ((.files // []) | type == "array" and all(type == "string" and length > 0 and (startswith("/") | not)
      and (contains("..") | not) and (startswith(".git") | not)))
    and (.re_request | type == "array" and all(type == "string"))
    and (.replies | type == "array" and all(
      (.body | type == "string" and length > 0 and length < 3000)
      and (.in_reply_to == null or (.in_reply_to as $i | $cm[0] | any(.id == $i)))))' "$r" >/dev/null ||
    fail "result.json is malformed or replies to a comment id that does not exist"

  # Reply cap: at most one per open human comment, never more than 20.
  local cap
  cap=$(jq -n --arg me "$me" --slurpfile c "$JOB/comments.json" --slurpfile i "$JOB/issue-comments.json" \
    --slurpfile v "$JOB/reviews.json" '[$c[0][], $i[0][], ($v[0][] | select((.body // "") != ""))]
    | map(select(.user.login != $me and (.user.login | endswith("[bot]") | not))) | length | if . > 20 then 20 else . end')
  [ "$(jq '.replies | length' "$r")" -le "$cap" ] || fail "result.json has $(jq '.replies | length' "$r") replies but there are only $cap open human comments (cap)"

  # Only the files the model lists are committed, never `git add -A`.
  local dirty changed summary msg newsha files=() f
  while IFS= read -r f; do files+=("$f"); done < <(jq -r '(.files // [])[]' "$r")
  dirty=0
  [ ${#files[@]} -eq 0 ] || dirty=$(git -C "$WT" status --porcelain -- "${files[@]}" | wc -l | tr -d ' ')
  git -C "$WT" status --porcelain | cut -c4- | while IFS= read -r f; do
    case " ${files[*]-} " in *" $f "*) ;; *) echo "not committed (not listed in result.json): $f" >>"$LOG" ;; esac
  done
  summary=$(jq -r '.summary' "$r" | cut -c1-200)
  nreplies=$(jq '.replies | length' "$r")
  # Re-request: whoever the model lists, plus every human whose latest review requests changes,
  # once this job fixed or answered something (a declined point still deserves their look).
  local want acted=false
  { [ "$dirty" -gt 0 ] || [ "$nreplies" -gt 0 ]; } && acted=true
  want=$(jq -r --slurpfile rv "$JOB/reviews.json" --arg me "$me" --argjson acted "$acted" '
    ($rv[0] | map(select(.state != "PENDING")) | group_by(.user.login) | map(max_by(.id))
      | map(select(.state == "CHANGES_REQUESTED") | .user.login)) as $cr
    | [.re_request[], (if $acted then $cr[] else empty end)]
    | map(select(. != $me and (endswith("[bot]") | not)))
    | map(select(. as $l | $rv[0] | any(.user.login == $l))) | unique | .[]' "$r")
  check_head
  if [ "$dry" = true ]; then
    local lg; lg=$(for l in $want; do printf '@%s ' "$l"; done | sed 's/ $//; s/ /, /g')
    succeed "I would have $([ "$dirty" -gt 0 ] && echo "fixed: $summary ($dirty files), pushed, ")replied on $nreplies thread(s)$([ -n "$lg" ] && echo ", re-requested review from $lg") (nothing was pushed or posted)."
  fi
  live_now
  abort_if_paused
  [ "$dirty" -eq 0 ] || run_local_tests
  newsha=$head
  if [ "$dirty" -gt 0 ]; then
    msg=$(jq -r '.commit_message // "Address review feedback"' "$r" | head -c 300 | defang)
    [ -n "$msg" ] || msg="Address review feedback"
    git -C "$WT" add -A -- "${files[@]}" >>"$LOG" 2>&1 || fail "git add failed"
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
    body=$(jq -r --arg s "$short" ".replies[$idx].body | gsub(\"\\\\{\\\\{sha\\\\}\\\\}\"; \$s)" "$r" | defang)
    posted=1
    if [ -n "$id" ]; then resp=$(gh api "repos/$repo/pulls/$n/comments/$id/replies" -f body="$body" 2>>"$LOG")
    else resp=$(gh api "repos/$repo/issues/$n/comments" -f body="$body" 2>>"$LOG"); fi
    if [ -n "$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)" ]; then nposted=$((nposted + 1))
    else errs="$errs reply $((idx + 1)) failed;"; fi
  done

  local args=() l missing=""
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

# =============================== conflict: check, commit the merge, push ===============================
finish_conflict() {
  local r=$JOB/result.json f bad="" files=() nf=0 newsha summary="" left
  if [ -z "$skip_model" ]; then
    [ -s "$r" ] || fail "the model wrote no result.json"
    jq -e '(.summary | type == "string") and ((.unresolved // []) | type == "array")' "$r" >/dev/null ||
      fail "result.json is malformed"
    if [ "$(jq '(.unresolved // []) | length' "$r")" -gt 0 ]; then
      git -C "$WT" merge --abort >>"$LOG" 2>&1
      succeed "I did not resolve the merge conflicts: $(jq -r '[.unresolved[] | "\(.file): \(.why)"] | join("; ")' "$r" | cut -c1-300). Please merge $base in by hand."
    fi
    summary=$(jq -r .summary "$r" | cut -c1-200)
    # Only the conflicted files may change; anything else the model touched is put back.
    git -C "$WT" diff --name-only | sort -u | while IFS= read -r f; do
      grep -qxF "$f" "$JOB/conflicts.txt" ||
        { git -C "$WT" checkout -- "$f" 2>>"$LOG"; echo "put back (not a conflicted file): $f" >>"$LOG"; }
    done
    while IFS= read -r f; do
      files+=("$f"); nf=$((nf + 1))
      grep -qE '^(<<<<<<<|>>>>>>>)( |$)' "$WT/$f" && bad="$bad $f"
      case $f in *.json) jq empty "$WT/$f" >/dev/null 2>&1 || bad="$bad $f(invalid JSON)" ;; esac
    done <"$JOB/conflicts.txt"
    [ -z "$bad" ] || fail "conflict markers or broken files left after resolving:$bad"
    git -C "$WT" add -- "${files[@]}" >>"$LOG" 2>&1 || fail "git add of the resolved files failed"
  fi
  left=$(git -C "$WT" diff --name-only --diff-filter=U)
  [ -z "$left" ] || fail "still unmerged after resolving: $left"
  local what_done="merged $base into your branch"
  [ "$nf" -gt 0 ] && what_done="$what_done and resolved conflicts in $nf file(s) (${files[*]})${summary:+: $summary}"
  check_head
  [ "$dry" = true ] && succeed "I would have $what_done and pushed (nothing was pushed)."
  live_now
  abort_if_paused
  # Hooks off, as in the fix path: a hooksPath set by the repo (husky) would run the PR's code here.
  git -C "$WT" -c core.hooksPath=/dev/null commit -q --no-edit -m "Merge $base into $branch" >>"$LOG" 2>&1 ||
    fail "git commit of the merge failed"
  newsha=$(git -C "$WT" rev-parse HEAD)
  posted=1
  git -C "$WT" -c core.hooksPath=/dev/null push -q --no-verify origin "HEAD:refs/heads/$branch" >>"$LOG" 2>&1 ||
    { posted=0; fail "git push was rejected (not forced, remote probably moved)"; }
  local i seen=""
  for i in 1 2 3 4 5; do
    seen=$(gh_get "repos/$repo/pulls/$n" --jq .head.sha); [ "$seen" = "$newsha" ] && break; sleep 2
  done
  [ "$seen" = "$newsha" ] || fail "pushed ${newsha:0:7} but GitHub shows head ${seen:0:7}"
  succeed "I $what_done, pushed ${newsha:0:7} (verified on GitHub). CI runs the tests."
}

# =============================== cifix: push a fix, re-run once, or hand over ===============================
finish_cifix() {
  local r=$JOB/result.json action summary files=() f dirty msg newsha runs run
  [ -s "$r" ] || fail "the model wrote no result.json"
  jq -e '((.action // "") | IN("fix", "rerun", "none")) and (.summary | type == "string")
    and ((.files // []) | type == "array" and all(type == "string" and length > 0 and (startswith("/") | not)
      and (contains("..") | not) and (startswith(".git") | not)))' "$r" >/dev/null ||
    fail "result.json is malformed"
  action=$(jq -r .action "$r")
  summary=$(jq -r .summary "$r" | cut -c1-250)
  check_head
  if [ "$action" = none ]; then
    succeed "I did not fix the failing CI: $summary. This one needs you."
  fi
  if [ "$action" = rerun ]; then
    # Flaky or infrastructure failure: re-run the failed GitHub Actions jobs. Once per commit: the
    # job key is the head sha, so a second red run on the same commit is left to the user.
    runs=$(jq -r '.[] | (.details_url // "") | select(test("/actions/runs/[0-9]+"))
      | capture("/actions/runs/(?<r>[0-9]+)").r' "$JOB/ci/failed.json" | sort -u)
    [ -n "$runs" ] ||
      succeed "I think the CI failure is not caused by the code ($summary), but there is no GitHub Actions run I can re-run. This one needs you."
    [ "$dry" = true ] && succeed "I would have re-run the failed CI jobs: $summary (nothing was re-run)."
    live_now
    abort_if_paused
    posted=1
    for run in $runs; do
      gh api -X POST "repos/$repo/actions/runs/$run/rerun-failed-jobs" >/dev/null 2>>"$LOG" ||
        fail "re-running the failed jobs of run $run failed"
    done
    succeed "I re-ran the failed CI jobs once: $summary. If they fail again on this commit, it needs you."
  fi
  # action fix: commit only the files the model lists, never `git add -A`.
  while IFS= read -r f; do files+=("$f"); done < <(jq -r '(.files // [])[]' "$r")
  [ ${#files[@]} -gt 0 ] || fail "the model chose fix but listed no files"
  dirty=$(git -C "$WT" status --porcelain -- "${files[@]}" | wc -l | tr -d ' ')
  [ "$dirty" -gt 0 ] || fail "the model chose fix but the listed files are unchanged"
  [ "$dry" = true ] && succeed "I would have fixed the failing CI: $summary ($dirty files) and pushed (nothing was pushed)."
  live_now
  abort_if_paused
  run_local_tests
  msg=$(jq -r '.commit_message // "Fix failing CI"' "$r" | head -c 300 | defang)
  [ -n "$msg" ] || msg="Fix failing CI"
  git -C "$WT" add -A -- "${files[@]}" >>"$LOG" 2>&1 || fail "git add failed"
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
  succeed "I fixed the failing CI: $summary, pushed ${newsha:0:7} (verified on GitHub). CI runs again."
}

if [ "$kind" = review ]; then finish_review
elif [ "$kind" = conflict ]; then finish_conflict
elif [ "$kind" = cifix ]; then finish_cifix
else finish_fix; fi
