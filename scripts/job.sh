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
JOB_START=$(date -u +%FT%TZ) # read-backs after an ambiguous write only accept what was created since now
LOG=$STATE_DIR/logs/$stamp-$slug-$n-$kind.log
JOB=$STATE_DIR/jobs/$stamp-$slug-$n-$kind-$$
WT=$STATE_DIR/worktrees/$slug-$n-$kind-$$
REF=refs/pr-autopilot/$n-$$ BASEREF=refs/pr-autopilot/base-$n-$$
mkdir -p "$JOB"
export PR_AUTOPILOT_TRANSIENT_FILE=$JOB/transient # set by lib.sh gh() when retries ran out on a network error
echo "# $stamp $kind $repo#$n head=$head dry_run=$dry" >"$LOG"
clone=$(jq -r --arg r "$repo" '.repos | to_entries[] | select(.key | ascii_downcase == ($r | ascii_downcase)) | .value' "$CONFIG")

if [ "$kind" = review ]; then what="$who asked you to review it"
elif [ "$kind" = conflict ]; then what="yours has merge conflicts with $base"
elif [ "$kind" = cifix ]; then what="$(ci_local && echo "local ")CI failed on yours"
elif [ "$cr" = true ]; then what="$who requested changes on yours"
else what="$who commented on yours"; fi
# The PR link leads the notification: a click cannot open it, so it has to be readable.
prefix="PR #$n ($title): $what."
[ "$kind" = cilocal ] && prefix="PR #$n ($title):" # its outcome says it: "local CI passed on #N (sha8)"
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

# transient.tsv: "epoch<TAB>key" of runs not counted as an attempt (GitHub unreachable, claude limit).
# Only the last 24h count toward the cap of 5, so it can neither loop forever nor linger.
transient_count() { cat "$STATE_DIR/transient.tsv" 2>/dev/null | awk -F'\t' -v k="$DKEY" -v t="$(($(date +%s) - 86400))" '$2 == k && $1 > t {c++} END {print c + 0}'; }
note_transient() { printf '%s\t%s\n' "$(date +%s)" "$DKEY" >>"$STATE_DIR/transient.tsv"; }

fail_extra="" # what the owner must still see when a job fails late (escalation, records already made)
fail() { # fail <message>: loud report; retried by the poller (max 3) unless we already wrote to GitHub
  local nf
  set -- "$1${fail_extra:+.$fail_extra}"
  echo "FAILED: $1" >>"$LOG"
  if [ "$posted" = 1 ]; then
    echo "$DKEY" >>"$STATE_DIR/handled.tsv"; note_fix # a repeat could double-post
    report "$prefix PARTLY DONE, then FAILED: $1. Not retried automatically, check the PR. Log: $LOG."
  elif [ -e "$PR_AUTOPILOT_TRANSIENT_FILE" ] && [ "$(transient_count)" -lt 5 ]; then
    # GitHub was unreachable even after gh()'s retries: not the PR's fault, so no attempt is burned and
    # the next poll starts over. At most 5 times per key, then it counts like any failure.
    note_transient
    log "$repo#$n: GitHub unreachable ($1), not counted as an attempt, retrying next poll"
  else
    printf '%s\t%s\n' "$(date +%s)" "$DKEY" >>"$STATE_DIR/failed.tsv"
    nf=$(awk -F'\t' -v k="$DKEY" '$2 == k' "$STATE_DIR/failed.tsv" | wc -l | tr -d ' ')
    report "$prefix FAILED (attempt $nf of 3$([ "$nf" -ge 3 ] && echo ", giving up")): $1. Log: $LOG."
  fi
  exit 1
}
# A finished feedback fix, for the poller's max_feedback_fixes cap (per head and per PR).
note_fix() { [ "$kind" != fix ] || printf '%s\t%s\n' "$mode|$repo|$n" "$head" >>"$STATE_DIR/fixes.tsv"; }
succeed() { # succeed <outcome verified on GitHub>
  echo "$DKEY" >>"$STATE_DIR/handled.tsv"; note_fix
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
# own_comment <comments endpoint> <body> [reply-to comment id]: the JSON of our own comment with exactly
# this body, created since this job started (and in that thread), if there is one. Without the time and
# thread checks a repeated short reply would match an older comment. After a POST that failed ambiguously (the server may have applied it) this tells "already there"
# from "never arrived", so a retry cannot post twice.
own_comment() {
  gh_get --paginate "$1" | jq -s --arg me "$me" --arg b "$2" --arg since "$JOB_START" --arg rt "${3:-}" \
    'def n: gsub("\r"; "") | sub("\\s+$"; ""); [add // [] | .[] | select(.user.login == $me and (.body | n) == ($b | n)
      and (.created_at // "") >= $since and ($rt == "" or (.in_reply_to_id | tostring) == $rt))] | first // empty'
}

# --- preflight
me=$(gh api user --jq .login 2>>"$LOG"); [ -n "$me" ] || fail "gh api user failed (not logged in or offline)"
[ -d "$clone/.git" ] || [ -f "$clone/.git" ] || fail "clone path '$clone' is not a git checkout (fix config.json)"
ourl=$(git -C "$clone" config --get remote.origin.url | tr 'A-Z' 'a-z'); rl=$(tr 'A-Z' 'a-z' <<<"$repo")
case $ourl in
  *[:/]"$rl" | *[:/]"$rl".git) ;;
  *) fail "the clone's origin ($ourl) does not point at $repo, refusing to fetch or push" ;;
esac
abort_if_paused

# --- local CI (ci_source local): run ci-local on this head and report its record. No model and no
# checkout here: ci-local makes its own worktree and writes nothing to GitHub. The poller starts one
# of these at a time. Also in dry-run: it is the CI, not a write.
if [ "$kind" = cilocal ]; then
  check_head
  rec=$(ci_record "$repo" "$head") rc=0
  ci_tmo=$(cfgd ci_timeout_minutes 90)
  # ci-local runs only my own PRs' code here. A teammate's PR code never runs on this Mac: only
  # through the ci_container runner (config), and with none set, not at all.
  # My own PR means: I opened it AND every commit's GitHub author is me. A commit someone else pushed to
  # my branch (or one GitHub cannot tie to an account) makes it a teammate case. The commits API stops
  # at 250: a list that long may hide one, so it counts as a teammate case too.
  runner=$CI_LOCAL
  if [ "$(g '.author // ""')" != "$me" ]; then
    runner=$(ci_container)
    [ -n "$runner" ] || fail "local CI not run on $(g '.author // "?"')'s PR: their code never runs on this Mac outside a container, and ci_container is not set"
  else
    commits=$(gh_get --paginate "repos/$repo/pulls/$n/commits" | jq -s 'add // []') || fail "could not list the PR's commits"
    jq -e --arg h "$head" 'any(.[]; .sha == $h)' <<<"$commits" >/dev/null || skip_quietly "head moved before local CI"
    others=$(jq -r --arg me "$me" 'if length >= 250 then "250 or more commits, not all of them visible" else
      [.[] | .author.login // "an unknown author" | select(. != $me)] | unique | if length > 0 then "commits by " + join(", ") else "" end end' <<<"$commits")
    if [ -n "$others" ]; then
      runner=$(ci_container)
      [ -n "$runner" ] || succeed "local CI not run on #$n (${head:0:8}): it has $others; code that is not all yours never runs on this Mac outside a container, and ci_container is not set."
    fi
  fi
  if [ ! -s "$rec" ]; then
    [ -x "$runner" ] || fail "ci_source is local but $runner is not an executable"
    echo "running: $runner $n --repo $repo (timeout ${ci_tmo}m)" >>"$LOG"
    set -m
    with_timeout $((ci_tmo * 60)) "$runner" "$n" --repo "$repo" >>"$LOG" 2>&1 </dev/null &
    cpid=$!
    set +m
    wait "$cpid"; rc=$?; cpid=""
    echo "ci-local exited with status $rc" >>"$LOG"
  fi
  if [ ! -s "$rec" ]; then
    check_head # the head moved: ci-local ran the new one
    [ "$rc" -ne 124 ] || fail "ci-local timed out after ${ci_tmo}m (ci_timeout_minutes) and wrote no record for ${head:0:8}"
    fail "ci-local exited with status $rc and wrote no record for ${head:0:8}"
  fi
  sum=$(ci_summary "$rec") || fail "the ci-local record $rec is unreadable"
  succeed "$sum."
fi

# --- pre-fetch everything the model may read into the job dir (all of it is untrusted data)
gh_get "repos/$repo/pulls/$n" >"$JOB/pr.json" || fail "fetch PR failed"
[ "$(jq -r .head.sha "$JOB/pr.json")" = "$head" ] || skip_quietly "head moved before start"
if gh pr diff "$n" --repo "$repo" >"$JOB/diff.patch" 2>>"$LOG"; then
  echo "diff: single call (gh pr diff)" >>"$LOG"
else
  # GitHub refuses a whole-PR diff past 20000 lines (HTTP 406); the per-file API has no such cap,
  # but omits `patch` for files that are individually too large.
  echo "diff: single call failed, falling back to the paginated files API" >>"$LOG"
  # A filename may hold newlines or other control chars; unescaped they would fake extra diff lines.
  gh api --paginate "repos/$repo/pulls/$n/files" 2>>"$LOG" | jq -rs 'def c: gsub("[\u0000-\u001f]"; " ");
    add // [] | .[] | (.filename | c) as $f | ((.previous_filename // .filename) | c) as $p |
    "diff --git a/\($p) b/\($f)\n# status: \(.status)\n" +
    (if .patch then "--- a/\($p)\n+++ b/\($f)\n\(.patch)" else "(patch too large or binary, read the file in the checkout)" end) + "\n"' \
    >"$JOB/diff.patch" || fail "fetch diff failed"
  [ -s "$JOB/diff.patch" ] || fail "fetch diff failed (files API returned nothing)"
  echo "diff: per-file patches from the files API ($(grep -c '^diff --git' "$JOB/diff.patch") files, $(grep -c '^(patch too large' "$JOB/diff.patch") without a patch)" >>"$LOG"
  # The files API stops at 3000 files; a short list means the model would review a partial diff unknowingly.
  nfiles=$(grep -c '^diff --git' "$JOB/diff.patch"); nchanged=$(jq -r '.changed_files // 0' "$JOB/pr.json")
  if [ "$nfiles" -lt "$nchanged" ]; then
    warn="# WARNING: PARTIAL DIFF. The files API returned $nfiles of $nchanged changed files (it caps at 3000). Files missing below are NOT shown; read them from the checkout (git diff against the base)."
    echo "WARNING: partial diff, $nfiles of $nchanged changed files" >>"$LOG"
    { echo "$warn"; cat "$JOB/diff.patch"; } >"$JOB/diff.patch.tmp" && mv "$JOB/diff.patch.tmp" "$JOB/diff.patch"
  fi
fi
for ep in reviews comments issue-comments; do
  case $ep in
    reviews) path="repos/$repo/pulls/$n/reviews" ;;
    comments) path="repos/$repo/pulls/$n/comments" ;;
    issue-comments) path="repos/$repo/issues/$n/comments" ;;
  esac
  gh api --paginate "$path" 2>>"$LOG" | jq -s 'add // []' >"$JOB/$ep.json" || fail "fetch $ep failed"
  [ -s "$JOB/$ep.json" ] || fail "fetch $ep returned nothing"
  # Own PR: only trusted voices reach the model (trust.jq, the rule classify.jq triggers on); a stranger's
  # text never does, and neither does a whole review thread a stranger started (a review bot or anyone
  # answering in it would relay them). A thread's root is in_reply_to_id (GitHub points every reply at
  # it); a root not in the list counts as untrusted. Not on a review of someone else's PR: there the
  # whole PR is the untrusted input being judged.
  if [ "$kind" != review ]; then
    jq -L "$DIR" --arg me "$me" --argjson bots "$(review_bots)" --argjson tr "$(jq -c '.trusted_commenters // []' "$CONFIG")" \
      --argjson ig "$(jq -c '.ignore_authors // []' "$CONFIG")" 'include "trust";
      def tv: {login: .user.login, assoc: .author_association} | tvoice($me; $ig; $bots; $tr);
      (map(select(tv) | .id)) as $ok | map(select(tv and ((.in_reply_to_id // .id) | IN($ok[]))))' \
      "$JOB/$ep.json" >"$JOB/$ep.trusted" && mv "$JOB/$ep.trusted" "$JOB/$ep.json" || fail "could not filter $ep to trusted authors"
  fi
done
# Which review threads are resolved: only GraphQL says, and a resolved thread is not an open point.
if [ "$kind" = fix ]; then
  review_threads "$repo" "$n" >"$JOB/threads.json" 2>>"$LOG" || fail "fetch review threads failed"
fi

# --- checkout of the PR head without the repo's agent config (it is untrusted)
git_net -C "$clone" fetch -q origin "+pull/$n/head:$REF" "+refs/heads/$base:$BASEREF" >>"$LOG" 2>&1 ||
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
# How anything that gets posted should read, shared by every skill; copied in because the model reads
# only the checkout and the job dir. voice_check (lib.sh) enforces its "Never" list before posting.
cp "$PLUGIN_ROOT/voice.md" "$JOB/voice.md" || fail "could not copy voice.md into the job dir"
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
if [ "$kind" = cifix ] && ci_local; then
  # Local CI: the failing jobs of this head's ci-local record, each with its command and log tail.
  mkdir -p "$JOB/ci"
  rec=$(ci_record "$repo" "$head")
  jq -e --arg h "$head" '.sha == $h and (.result | IN("fail", "incomplete"))' "$rec" >/dev/null 2>&1 ||
    skip_quietly "no failing local CI record for this commit any more"
  ci_i=0
  while IFS= read -r ci_j; do
    ci_i=$((ci_i + 1))
    ci_name=$(jq -r '.job' <<<"$ci_j") ci_src=$(jq -r '.log // ""' <<<"$ci_j")
    ci_log="$JOB/ci/$ci_i-$(printf '%s' "$ci_name" | tr -c 'A-Za-z0-9._-' _ | cut -c1-60).log"
    if [ -f "$ci_src" ] && tail -n 400 "$ci_src" >"$ci_log" && [ -s "$ci_log" ]; then :
    else echo "could not read the log of $ci_name ($ci_src)" >>"$LOG"; ci_log=""; fi
    jq -c --arg l "$ci_log" '{name: .job, workflow, conclusion: (if .skipped_reason then "skipped" else "failure" end),
      command, exit_code, skipped_reason, log: (if $l == "" then null else $l end)}' <<<"$ci_j"
  done < <(jq -c '.jobs[] | select(.exit_code != 0 or .skipped_reason != null)' "$rec") | jq -s . >"$JOB/ci/failed.json" ||
    fail "could not read the failing jobs from $rec"
  [ "$(jq length "$JOB/ci/failed.json")" -gt 0 ] ||
    succeed "$(ci_summary "$rec"). No job to fix, ci-local could not run it; this one needs you."
elif [ "$kind" = cifix ]; then
  mkdir -p "$JOB/ci"
  gh_get "repos/$repo/commits/$head/check-runs?per_page=100" | jq '[.check_runs[]
    | select((.conclusion // "") | IN("failure", "timed_out"))
    | {id, name, conclusion, details_url, app: (.app.slug // ""), title: (.output.title // ""),
       summary: ((.output.summary // "") | .[0:4000]), text: ((.output.text // "") | .[0:4000])}]' \
    >"$JOB/ci/failed.json" || fail "could not fetch the failing checks"
  [ "$(jq length "$JOB/ci/failed.json")" -gt 0 ] || skip_quietly "no failing check on this commit any more"
  # Each fetched log's exact path goes into failed.json as "log": the model cannot list ci/, so it
  # must not have to guess file names.
  ci_i=0
  : >"$JOB/ci/logs.tsv"
  while IFS=$'\t' read -r ci_id ci_name ci_app; do
    ci_i=$((ci_i + 1))
    [ "$ci_app" = github-actions ] || continue
    ci_log="$JOB/ci/$ci_i-$(printf '%s' "$ci_name" | tr -c 'A-Za-z0-9._-' _ | cut -c1-60).log"
    if gh api "repos/$repo/actions/jobs/$ci_id/logs" 2>>"$LOG" | tail -n 400 >"$ci_log" && [ -s "$ci_log" ]; then
      printf '%s\t%s\n' "$ci_id" "$ci_log" >>"$JOB/ci/logs.tsv"
    else
      echo "could not fetch the log of $ci_name" >>"$LOG"
    fi
  done < <(jq -r '.[] | [.id, .name, .app] | @tsv' "$JOB/ci/failed.json")
  jq --rawfile t "$JOB/ci/logs.tsv" '($t | split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add // {}) as $m
    | map(. + {log: ($m[(.id | tostring)] // null)})' "$JOB/ci/failed.json" >"$JOB/ci/failed.json.tmp" &&
    mv "$JOB/ci/failed.json.tmp" "$JOB/ci/failed.json" || fail "could not record the CI log paths"
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
stall_s=${PR_AUTOPILOT_STALL_SECONDS:-$(($(cfgd stall_minutes 8) * 60))} # env: tests only
cd "$WT" || fail "cannot enter worktree"
abort_if_paused
total_cost=0
# run_claude <prompt> <out.jsonl>: sets rc. Own process group so pause or the timeout kill all of it.
run_claude() {
  rm -f "$PR_AUTOPILOT_TRANSIENT_FILE" # a tolerated gh failure earlier must not excuse a claude failure
  set -m
  claude -p "$1" --plugin-dir "$PLUGIN_ROOT" --permission-mode dontAsk \
    --setting-sources "" --strict-mcp-config --settings '{"disableAllHooks":true}' \
    --add-dir "$JOB" --allowedTools "$(join "${allow[@]}")" --disallowedTools "$(join "${deny[@]}")" \
    --output-format stream-json --verbose --no-session-persistence </dev/null >"$2" 2>>"$LOG" &
  cpid=$!
  set +m
  # Watchdog: the outer cap (job_timeout_minutes), and no progress: claude's stream has not grown for
  # stall_s seconds (an outage stalls its API calls with no error, 2026-10-14).
  rm -f "$JOB/stalled"
  (
    start=$SECONDS since=$SECONDS last=-1 why="" step=15
    [ "$stall_s" -ge 60 ] || step=1
    while kill -0 "$cpid" 2>/dev/null; do
      sleep "$step"
      sz=$(wc -c <"$2" 2>/dev/null | tr -d ' ')
      if [ "$sz" != "$last" ]; then last=$sz since=$SECONDS; fi
      if [ $((SECONDS - start)) -ge $((tmo * 60)) ]; then why="timeout after ${tmo}m"
      elif [ $((SECONDS - since)) -ge "$stall_s" ]; then why="stalled: claude wrote nothing for ${stall_s}s"; : >"$JOB/stalled"; fi
      [ -z "$why" ] || { echo "$why" >>"$LOG"; kill -TERM -- "-$cpid"; kill "$cpid"; exit 0; }
    done
  ) 2>/dev/null &
  wd=$!; disown "$wd"
  wait "$cpid"; rc=$?
  stop_wd; cpid=""
  # A stall while GitHub is unreachable is the outage, not this PR: not an attempt (fail() checks the
  # file). Re-checked once; a stall with GitHub up counts like any failure.
  if [ "$rc" -ne 0 ] && [ -e "$JOB/stalled" ]; then
    if gh api user >/dev/null 2>>"$LOG"; then fail "claude wrote nothing for ${stall_s}s and was stopped (GitHub was reachable)"; fi
    : >"$PR_AUTOPILOT_TRANSIENT_FILE"
    fail "claude wrote nothing for ${stall_s}s and GitHub is unreachable"
  fi
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
  # A spent plan is not this PR's fault: no attempt burned, and the poller starts no jobs for 30 minutes.
  # Only claude's own final error result counts: the phrase may sit in PR content in tool results.
  if [ "$rc" -ne 0 ] && jq -e '.is_error == true and ((.result // "") | test("hit your session limit"))' "$JOB/claude.json" >/dev/null 2>&1 &&
    [ "$(transient_count)" -lt 5 ]; then
    note_transient
    echo "claude session limit reached, job not counted as an attempt" >>"$LOG"
    log "$repo#$n: claude session limit reached, pausing job starts for 30 minutes"
    touch "$STATE_DIR/claude_limited"
    exit 0
  fi
  [ "$rc" -eq 0 ] || fail "claude exited with status $rc (143 or 137 usually means the timeout)"
  [ "$(jq -r '.is_error // false' "$JOB/claude.json" 2>/dev/null)" = false ] ||
    fail "claude reported an error: $(jq -r '.result // "?"' "$JOB/claude.json" | head -c 200)"

  cost_check
fi

# =============================== review: post the draft ===============================
# ci_review_note <record>: what a review says about failing local CI: the summary, then the last lines
# of each failing job's log (at most 3 jobs, 15 lines each). Log text is untrusted: a fence in it is
# broken up so it cannot close ours, and the whole body is defanged before posting.
ci_review_note() {
  local s j log
  s=$(ci_summary "$1") || return 1
  printf '%s.\n' "L${s#l}"
  while IFS=$'\t' read -r j log; do
    [ -f "$log" ] || continue
    printf '\nLast lines of %s:\n\n```\n' "$j"
    tail -n 15 "$log" | cut -c1-200 | sed 's/```/` ` `/g'
    printf '```\n'
  done < <(jq -r '[.jobs[] | select(.exit_code != 0 or .skipped_reason != null)][0:3][] | [.job, (.log // "")] | @tsv' "$1")
}
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
  local ap="" tells fixes=""
  [ "$event" = APPROVE ] && ap=approve
  tells=$(voice_check $ap <"$JOB/body.md")
  if [ "$body_words" -gt 150 ] || [ -n "$tells" ]; then
    # Do not throw a whole review away over length or voice: one cheap follow-up asks for a rewrite.
    [ "$body_words" -le 150 ] || fixes="shorten the body to at most 140 words, dropping nitpicks, filler and repetition first. "
    [ -z "$tells" ] || fixes="${fixes}It reads machine-written, so rewrite it by $JOB/voice.md and remove: $tells. "
    echo "draft is $body_words words${tells:+ and has $tells}, asking for a rewrite" >>"$LOG"
    abort_if_paused
    run_claude "REWRITE the review draft at $JOB/draft.md: ${fixes}Keep the first line (VERDICT) exactly as it is, keep every blocker with its file:line and failure, and keep the findings and their severity. Edit that file only. Do not review anything again. job_dir=$JOB" "$JOB/claude-rewrite.jsonl"
    cost_check
    [ "$rc" -eq 0 ] || fail "claude exited with status $rc while rewriting the draft"
    verdict2=$(head -1 "$JOB/draft.md" | tr -d '\r')
    [ "$verdict2" = "$verdict" ] || fail "the rewrite changed the VERDICT line"
    tail -n +2 "$JOB/draft.md" | sed '/./,$!d' >"$JOB/body.md"
    body_words=$(wc -w <"$JOB/body.md" | tr -d ' ')
    [ "$body_words" -gt 0 ] || fail "the rewritten draft has no body"
    tells=$(voice_check $ap <"$JOB/body.md")
  fi
  [ "$body_words" -le 150 ] || fail "draft body is $body_words words even after asking for a rewrite, limit is 150"
  [ -z "$tells" ] || fail "the draft still reads machine-written after a rewrite ($tells)"
  why=$(head -1 "$JOB/body.md" | cut -c1-160)
  # Local CI: APPROVE only when this head's ci-local record is pass. Otherwise REQUEST_CHANGES (a
  # COMMENT when the code review found nothing), naming the failing jobs with the tail of their logs.
  # Only with a container runner: a teammate's code never runs on this Mac, so without ci_container the
  # review is what it was before local CI, and says local CI did not run.
  if ci_local && [ -z "$(ci_container)" ]; then
    printf '\nlocal CI not run: container runner not set up yet\n' >>"$JOB/body.md"
  elif ci_local; then
    local rec; rec=$(ci_record "$repo" "$head")
    [ -s "$rec" ] || fail "no local CI record for ${head:0:8} (the poller runs ci-local before the review)"
    if [ "$(jq -r --arg h "$head" 'if .sha == $h then .result else "for another commit" end' "$rec" 2>/dev/null)" != pass ]; then
      ci_review_note "$rec" >"$JOB/ci-note.md" || fail "the ci-local record $rec is unreadable"
      if [ "$event" = APPROVE ]; then event=COMMENT state=COMMENTED; cp "$JOB/ci-note.md" "$JOB/body.md"
      else { echo; cat "$JOB/ci-note.md"; } >>"$JOB/body.md"; fi
      why=$(ci_summary "$rec")
    fi
  fi

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
    -F body=@"$JOB/body.safe.md" 2>>"$LOG")
  rid=$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)
  if [ -z "$rid" ]; then # ambiguous failure: did the review land anyway?
    rid=$(gh_get --paginate "repos/$repo/pulls/$n/reviews" | jq -rs --arg me "$me" --arg h "$head" --arg s "$state" --arg since "$JOB_START" \
      '[add // [] | .[] | select(.user.login == $me and .commit_id == $h and .state == $s and (.submitted_at // "") >= $since)] | last | .id // empty')
    [ -z "$rid" ] || echo "review POST failed but the review is on GitHub ($rid), not re-sending" >>"$LOG"
  fi
  [ -n "$rid" ] || fail "posting the review failed"
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
# GitHub may store CRLF or trim trailing space; compare descriptions after normalising both.
NORM_BODY='(.body // "") | gsub("\r\n"; "\n") | sub("\\s+$"; "")'
body_unchanged() { # the description must be what the job read at start, or a new one would clobber an edit
  local now; now=$(gh_get "repos/$repo/pulls/$n" --jq "$NORM_BODY") || fail "cannot re-read the PR description"
  [ "$now" = "$(jq -r "$NORM_BODY" "$JOB/pr.json")" ] ||
    fail "the PR description changed while the job ran, so I did not overwrite it and posted no reply. NEEDS YOU: check the description against the review"
}
finish_fix() {
  local r=$JOB/result.json
  [ -s "$r" ] || fail "the model wrote no result.json"
  jq -e --slurpfile cm "$JOB/comments.json" '
    (.summary | type == "string") and (.commit_message // "x" | type == "string")
    and ((.files // []) | type == "array" and all(type == "string" and length > 0 and (startswith("/") | not)
      and (contains("..") | not) and (startswith(".git") | not)))
    and (.re_request | type == "array" and all(type == "string"))
    and (.replies | type == "array" and all(
      (.body | type == "string" and test("\\S") and length < 3000)
      and (.in_reply_to == null or (.in_reply_to as $i | $cm[0] | any(.id == $i)))))' "$r" >/dev/null ||
    fail "result.json is malformed or replies to a comment id that does not exist"

  # Reply cap: at most one per open comment (human, or a review bot's inline comment), never more than 20.
  local cap
  cap=$(jq -n --arg me "$me" --slurpfile c "$JOB/comments.json" --slurpfile i "$JOB/issue-comments.json" \
    --slurpfile v "$JOB/reviews.json" '[($c[0][] | select(.user.login != $me)),
      ([$i[0][], ($v[0][] | select((.body // "") != ""))][] | select(.user.login != $me and (.user.login | endswith("[bot]") | not)))]
    | length | if . > 20 then 20 else . end')
  [ "$(jq '.replies | length' "$r")" -le "$cap" ] || fail "result.json has $(jq '.replies | length' "$r") replies but there are only $cap open comments (cap)"

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

  # Posting gate, before any write: a reply must not promise what this job does not do. Each
  # promise ("I will ...") is listed in .promises and backed by the commit, the PR description edit
  # or a deferral this job records; a deferral ("belongs in a later PR") links that record; {{sha}}
  # needs a commit. The skill asks the model to check this itself; this is the mechanical backstop.
  jq -e '((.pr_body // "") | type == "string" and length < 60000)
    and ((.escalate // "") | type == "string" and length < 2000)
    and ((.deferrals // []) | type == "array" and all(
      (.body | type == "string" and test("\\S") and length < 3000)
      and ((.pr | type == "number" and . > 0 and . == floor) and .issue_title == null
        or .pr == null and (.issue_title | type == "string" and test("\\S") and length < 200))))
    and ((.promises // []) | type == "array" and all(
      (.reply | type == "number") and (.text | type == "string")
      and ((.done_by // "") | test("^(commit|pr_body|deferral:[0-9]+)$"))))' "$r" >/dev/null ||
    fail "result.json has a malformed pr_body, escalate, deferrals or promises field"
  local gate
  gate=$(jq -r --argjson dirty "$dirty" --argjson cur "$n" '
    (.deferrals // []) as $d | (.promises // []) as $p | (.pr_body // "") as $b | .replies as $rs
    | (.replies | to_entries[] | .key as $i | (.value.body | gsub("[\u2018\u2019\u02bc]"; "\u0027")) as $t
        | (if ($t | test("\\b(I|we)(\u0027| wi)ll\\b|\\b(I\u0027m|I am|we\u0027re|we are) going to\\b|\\bwill (now |also |then |soon )?(update|correct|fix|follow|add|change|open|file|address|handle|track|amend|edit|remove|rename|move|clarify|document|look|do|make|revisit|check)|\\bfollow(ing)? up\\b"; "i"))
              and ($p | any(.reply == $i) | not)
           then "reply \($i + 1) promises an action but no promise in result.json backs it" else empty end),
          (if ($t | contains("{{sha}}")) and $dirty == 0 then "reply \($i + 1) cites {{sha}} but nothing is committed" else empty end),
          (if ($t | test("(updated|corrected|fixed|edited|amended) the (PR )?description"; "i")) and $b == ""
           then "reply \($i + 1) says the PR description was changed but pr_body is empty" else empty end),
          (if ($t | test("belongs (in|to) |(separate|follow-?up|later|future|another|next|subsequent) PR|in a follow-?up|(later|follow-?up) (work|change|issue)|will be (handled|addressed|done|fixed) (in|by|later)"; "i"))
              and ($t | test("\\{\\{deferral:[0-9]+\\}\\}") | not)
           then "reply \($i + 1) defers the point but links no recorded deferral" else empty end),
          ($t | [scan("\\{\\{deferral:([0-9]+)\\}\\}")[0] | tonumber] | .[] | select(. >= ($d | length))
           | "reply \($i + 1) links deferral \(.) which does not exist")),
      ($p[] | if .reply < 0 or .reply >= ($rs | length) then "promise \"\(.text)\" points at no reply"
        elif .done_by == "commit" and $dirty == 0 then "promise \"\(.text)\" needs a commit but nothing is committed"
        elif .done_by == "pr_body" and $b == "" then "promise \"\(.text)\" needs the PR description edit but pr_body is empty"
        elif (.done_by | startswith("deferral:")) and ((.done_by[9:] | tonumber) >= ($d | length))
        then "promise \"\(.text)\" needs a deferral that does not exist" else empty end),
      ($d | to_entries[] | .key as $k
        | (if .value.pr == $cur then "deferral \($k) points at this PR itself" else empty end),
          (if ($rs | any(.body | contains("{{deferral:\($k)}}"))) then empty else "deferral \($k) is linked from no reply" end))' "$r") ||
    fail "could not check the replies in result.json"
  [ -z "$gate" ] || fail "posting blocked, the replies do not match what the job does: $(tr '\n' ';' <<<"$gate" | sed 's/;$//')"
  # Same voice rules as a review (voice.md): a reply that reads machine-written is not posted.
  local ri rt tells=""
  for ((ri = 0; ri < nreplies; ri++)); do
    rt=$(jq -r ".replies[$ri].body" "$r" | voice_check)
    [ -z "$rt" ] || tells="$tells reply $((ri + 1)): $rt;"
  done
  [ -z "$tells" ] || fail "posting blocked, a reply reads machine-written (see voice.md):${tells%;}"
  [ "$(jq '(.deferrals // []) | length' "$r")" -le 3 ] ||
    fail "refusing $(jq '.deferrals | length' "$r") deferrals (max 3), nothing written. NEEDS YOU: decide which of these points to fix here and which to track elsewhere"
  # A deferral into another PR goes only to the user's own open PR; anything else needs an issue.
  local dp
  for dp in $(jq -r '(.deferrals // [])[] | .pr // empty' "$r"); do
    [ "$(gh_get "repos/$repo/pulls/$dp" --jq '[.user.login, .state] | join(" ")')" = "$me open" ] ||
      fail "deferral target #$dp is not an open PR of yours; defer to a GitHub issue instead"
  done
  # Escalation to the owner: the model's own note, or, when a reviewer's latest review requests
  # changes and no code changed (docs or replies only), a generic one, so the owner decides instead
  # of the loop closing silently.
  local escalate codechanged=0 esc_note=""
  escalate=$(jq -r '.escalate // "" | gsub("\\s+"; " ") | ltrimstr(" ") | .[0:1500]' "$r")
  [ ${#files[@]} -eq 0 ] || codechanged=$(git -C "$WT" status --porcelain -- "${files[@]}" | cut -c4- |
    grep -cvE '(^|/)docs?/|\.(md|mdx|rst|txt|adoc)$')
  if [ -z "$escalate" ] && [ "$codechanged" -eq 0 ] && jq -e --arg me "$me" '
    map(select(.state != "PENDING" and .user.login != $me)) | group_by(.user.login) | map(max_by(.id))
    | any(.state == "CHANGES_REQUESTED")' "$JOB/reviews.json" >/dev/null; then
    escalate="A reviewer requested changes and I changed no code (docs or replies only). If the point is about correctness, security or data integrity, decide whether the code fix should be made."
  fi
  [ -z "$escalate" ] || esc_note=" NEEDS YOU: $escalate"
  fail_extra=$esc_note
  local new_body ndefer
  new_body=$(jq -r '.pr_body // ""' "$r" | defang)
  ndefer=$(jq '(.deferrals // []) | length' "$r")
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
  [ -z "$new_body" ] || body_unchanged
  if [ "$dry" = true ]; then
    local lg; lg=$(for l in $want; do printf '@%s ' "$l"; done | sed 's/ $//; s/ /, /g')
    succeed "I would have $([ "$dirty" -gt 0 ] && echo "fixed: $summary ($dirty files), pushed, ")$([ -n "$new_body" ] && echo "updated the PR description, ")$([ "$ndefer" -gt 0 ] && echo "recorded $ndefer deferral(s), ")replied on $nreplies thread(s)$([ -n "$lg" ] && echo ", re-requested review from $lg") (nothing was pushed or posted).$esc_note"
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
    git_net -C "$WT" -c core.hooksPath=/dev/null push -q --no-verify origin "HEAD:refs/heads/$branch" >>"$LOG" 2>&1 ||
      { posted=0; fail "git push was rejected (not forced, remote probably moved)"; }
    local i seen=""
    for i in 1 2 3 4 5; do
      seen=$(gh_get "repos/$repo/pulls/$n" --jq .head.sha); [ "$seen" = "$newsha" ] && break; sleep 2
    done
    [ "$seen" = "$newsha" ] || fail "pushed ${newsha:0:7} but GitHub shows head ${seen:0:7}"
  fi

  # The PR description (the user's own PR), read back to verify, before any reply says it changed.
  if [ -n "$new_body" ]; then
    body_unchanged
    posted=1
    gh api -X PATCH "repos/$repo/pulls/$n" -f body="$new_body" >/dev/null 2>>"$LOG" ||
      fail "editing the PR description failed"
    [ "$(gh_get "repos/$repo/pulls/$n" --jq "$NORM_BODY")" = "$(jq -rn --arg b "$new_body" "{body: \$b} | $NORM_BODY")" ] ||
      fail "edited the PR description but GitHub does not show the new text"
  fi
  # Deferrals: recorded where they will be seen, each linking back here, before any reply links them.
  local links='[]' di dbody dpr dtitle link esc_saved=$fail_extra
  for ((di = 0; di < ndefer; di++)); do
    dbody="$(jq -r ".deferrals[$di].body" "$r" | defang)

From the review on #$n: $url"
    dpr=$(jq -r ".deferrals[$di].pr // empty" "$r")
    posted=1
    if [ -n "$dpr" ]; then
      link=$(gh api "repos/$repo/issues/$dpr/comments" -f body="$dbody" --jq '.html_url // empty' 2>>"$LOG")
      [ -n "$link" ] || link=$(own_comment "repos/$repo/issues/$dpr/comments" "$dbody" | jq -r '.html_url // empty')
    else
      dtitle=$(jq -r ".deferrals[$di].issue_title" "$r" | defang)
      link=$(gh api "repos/$repo/issues" -f title="$dtitle" -f body="$dbody" --jq '.html_url // empty' 2>>"$LOG")
      [ -n "$link" ] || link=$(gh_get --paginate "repos/$repo/issues?creator=$me&state=open&per_page=100" | jq -rs --arg t "$dtitle" --arg b "$dbody" --arg since "$JOB_START" \
        'def n: gsub("\r"; "") | sub("\\s+$"; ""); [add // [] | .[] | select((.created_at // "") >= $since and .title == $t and (.body // "" | n) == ($b | n))] | first | .html_url // empty')
    fi
    [ -n "$link" ] || fail "recording deferral $di failed, no reply was posted"
    links=$(jq -c --arg l "$link" '. + [$l]' <<<"$links")
    fail_extra=" Already recorded, clean up if needed: $(jq -r 'join(", ")' <<<"$links").$esc_saved"
  done

  local short=${newsha:0:7} errs="" nposted=0 idx id body resp
  for ((idx = 0; idx < nreplies; idx++)); do
    id=$(jq -r ".replies[$idx].in_reply_to // empty" "$r")
    body=$(jq -r --arg s "$short" --argjson l "$links" ".replies[$idx].body | gsub(\"\\\\{\\\\{sha\\\\}\\\\}\"; \$s)
      | gsub(\"\\\\{\\\\{deferral:(?<k>[0-9]+)\\\\}\\\\}\"; \$l[.k | tonumber])" "$r" | defang)
    posted=1
    if [ -n "$id" ]; then resp=$(gh api "repos/$repo/pulls/$n/comments/$id/replies" -f body="$body" 2>>"$LOG")
    else resp=$(gh api "repos/$repo/issues/$n/comments" -f body="$body" 2>>"$LOG"); fi
    if [ -z "$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)" ]; then # ambiguous failure: already there?
      if [ -n "$id" ]; then resp=$(own_comment "repos/$repo/pulls/$n/comments" "$body" "$id")
      else resp=$(own_comment "repos/$repo/issues/$n/comments" "$body"); fi
    fi
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
  [ -n "$new_body" ] && out="$out, updated the PR description"
  [ "$ndefer" -gt 0 ] && out="$out, recorded $ndefer deferral(s) ($(jq -r 'join(", ")' <<<"$links"))"
  [ -n "$want" ] && out="$out, re-requested review from $(for l in $want; do printf '@%s ' "$l"; done | sed 's/ $//; s/ /, /g')"
  succeed "$out (verified on GitHub).$esc_note"
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
  # Opt-in local tests (run_local_tests_UNSAFE), sandboxed, before the merge is pushed: a resolution
  # that breaks a test fails here instead of on the PR. Without the opt-in, CI checks it and a red
  # build becomes a CI-fix job.
  run_local_tests
  # Hooks off, as in the fix path: a hooksPath set by the repo (husky) would run the PR's code here.
  git -C "$WT" -c core.hooksPath=/dev/null commit -q --no-edit -m "Merge $base into $branch" >>"$LOG" 2>&1 ||
    fail "git commit of the merge failed"
  newsha=$(git -C "$WT" rev-parse HEAD)
  posted=1
  git_net -C "$WT" -c core.hooksPath=/dev/null push -q --no-verify origin "HEAD:refs/heads/$branch" >>"$LOG" 2>&1 ||
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
  if [ "$action" = rerun ] && ci_local; then # GitHub jobs are never re-run as CI when CI is local
    succeed "I think the local CI failure is not caused by the code ($summary). Nothing is re-run; this one needs you."
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
  git_net -C "$WT" -c core.hooksPath=/dev/null push -q --no-verify origin "HEAD:refs/heads/$branch" >>"$LOG" 2>&1 ||
    { posted=0; fail "git push was rejected (not forced, remote probably moved)"; }
  local i seen=""
  for i in 1 2 3 4 5; do
    seen=$(gh_get "repos/$repo/pulls/$n" --jq .head.sha); [ "$seen" = "$newsha" ] && break; sleep 2
  done
  [ "$seen" = "$newsha" ] || fail "pushed ${newsha:0:7} but GitHub shows head ${seen:0:7}"
  local again="CI runs again."; ci_local && again="Local CI runs on the new head next."
  succeed "I fixed the failing CI: $summary, pushed ${newsha:0:7} (verified on GitHub). $again"
}

if [ "$kind" = review ]; then finish_review
elif [ "$kind" = conflict ]; then finish_conflict
elif [ "$kind" = cifix ]; then finish_cifix
else finish_fix; fi
