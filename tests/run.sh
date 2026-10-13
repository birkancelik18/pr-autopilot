#!/usr/bin/env bash
# No-network tests. Part 1: poll.sh against a fake gh and a stub job. Part 2: the real job.sh against
# a throwaway git repo, a fake gh and a fake claude. Usage: bash tests/run.sh
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1: expected '$2' got '$3'"; fi
}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/state"
cp "$T/fake-gh" "$W/bin/gh"; cp "$T/fake-claude" "$W/bin/claude"
printf '#!/usr/bin/env bash\necho "$@" >>"$PR_AUTOPILOT_STATE/notified"\n' >"$W/bin/osascript"
printf '#!/usr/bin/env bash\necho "TN $@" >>"$PR_AUTOPILOT_STATE/notified"; exit ${FAKE_TN_EXIT:-0}\n' >"$W/bin/terminal-notifier"
# BSD seq (macOS) counts down for "seq 0 -1" and prints 0 and -1; this shim shows that on any machine.
printf '#!/usr/bin/env bash\ni=$1; if [ "$1" -le "$2" ]; then s=1; else s=-1; fi\nwhile :; do echo $i; [ $i -eq $2 ] && break; i=$((i + s)); done\n' >"$W/bin/seq"
chmod +x "$W/bin/"* "$T/fake-job"
export PR_AUTOPILOT_GH_RETRY="0 0 0" PR_AUTOPILOT_SYNC_REPORT=1 PATH="$W/bin:$PATH" FIX="$W/fix" PR_AUTOPILOT_STATE="$W/state" PR_AUTOPILOT_CONFIG="$W/config.json"
S=$PR_AUTOPILOT_STATE
cp -R "$T/fixtures" "$FIX"
mkcfg() { # mkcfg <dry_run> [extra jq object]
  local extra=${2-}; [ -n "$extra" ] || extra='{}'
  jq -n --argjson dry "$1" --argjson extra "$extra" \
    '{repos: {"Acme/App": "/tmp/no-such-clone"}, dry_run: $dry, max_parallel: 9, ignore_authors: ["botty"]} + $extra' >"$PR_AUTOPILOT_CONFIG"
}
poll() { PR_AUTOPILOT_JOB="$T/fake-job" bash "$T/../scripts/poll.sh"; sleep 0.4; }
bump() { # bump <pr number> [updated_at]: GitHub bumps updated_at on any PR activity; so do we
  local v=${2:-2026-02-01T00:00:0$((++BUMP))Z} f
  for f in "$FIX"/search-*.json; do
    jq --argjson n "$1" --arg v "$v" '.items |= map(if .number == $n then .updated_at = $v else . end)' "$f" >"$W/b" && mv "$W/b" "$f"
  done
  for f in "$FIX"/notifications*.json; do
    jq --arg n "/pulls/$1" --arg v "$v" 'map(if (.subject.url | endswith($n)) then .updated_at = $v else . end)' "$f" >"$W/b" && mv "$W/b" "$f"
  done
}
BUMP=0
jobs_n() { wc -l <"$S/jobs.log" | tr -d ' '; }
plog() { grep -c -F -- "$1" "$S/polls.log"; }
: >"$S/jobs.log"

echo "== poller: classification and dedupe (dry-run)"
mkcfg true; poll
check "review #11, fix #12, review #19 (notifications page 2), review #20 (search only) start" 4 "$(jobs_n)"
check "PR #20 has no notification: found by the review-requested search alone" 1 "$(grep -cxF '["review","acme/app",20,"jjj000",true,"review|acme/app|20|jjj000"]' "$S/jobs.log")"
check "review job at head" 1 "$(grep -cxF '["review","acme/app",11,"aaa111",true,"review|acme/app|11|aaa111"]' "$S/jobs.log")"
check "fix key: latest CHANGES_REQUESTED review, inline comment and top-level comment ids" 1 \
  "$(grep -cxF '["fix","acme/app",12,"bbb222",true,"fix|acme/app|12|r901-v0-c5001-i7000"]' "$S/jobs.log")"
for why in "skip acme/app#13: draft" "skip acme/app#14: closed or merged" "skip acme/app#16: fork PR, allow_forks is off" \
  "skip acme/app#17: not actionable (reason: mention)" "skip acme/app#18: nothing to address"; do
  check "log: $why" 1 "$(plog "$why")"
done
check "repo not in config is ignored" 0 "$(plog 'other/x')"
poll; check "second poll starts nothing" 4 "$(jobs_n)"
jq '.head.sha = "aaa222"' "$FIX/pr-11.json" >"$W/x" && mv "$W/x" "$FIX/pr-11.json"
jq '. + [{"id":5003,"user":{"login":"bob"},"author_association":"MEMBER","body":"also this"}]' "$FIX/comments-12.json" >"$W/x" && mv "$W/x" "$FIX/comments-12.json"
bump 11; bump 12
poll; check "new head and new comment start exactly two more" 6 "$(jobs_n)"
poll; check "and then no more" 6 "$(jobs_n)"
mkcfg true '{"ignore_authors": []}'; : >"$S/seen.tsv"; poll
check "unignored non-[bot] author counts, [bot] logins and own comments never do" 1 \
  "$(grep -cxF '["fix","acme/app",18,"hhh888",true,"fix|acme/app|18|r0-v0-c6001-i0"]' "$S/jobs.log")"
check "carol's later APPROVED overrides her CHANGES_REQUESTED (no r id)" 0 "$(grep -c 'acme/app|18|r1' "$S/jobs.log")"

echo "== poller: failures retry at most 3 times with backoff"
jq '.head.sha = "iii000"' "$FIX/pr-19.json" >"$W/x" && mv "$W/x" "$FIX/pr-19.json"; bump 19
age() { awk -F'\t' -v t=$(($(date +%s) - 400)) 'BEGIN{OFS="\t"} {$1 = t; print}' "$S/failed.tsv" >"$W/f" && mv "$W/f" "$S/failed.tsv"; }
before=$(jobs_n)
FAKE_JOB_FAIL=1 poll; check "failing job ran once" $((before + 1)) "$(jobs_n)"
poll; check "recent failure: backing off" $((before + 1)) "$(jobs_n)"
age; FAKE_JOB_FAIL=1 poll; age; FAKE_JOB_FAIL=1 poll
check "retried after backoff, attempts 2 and 3" $((before + 3)) "$(jobs_n)"
age; poll; check "after 3 failures it gives up" $((before + 3)) "$(jobs_n)"
check "give-up is logged" 1 "$([ "$(plog 'gave up on')" -ge 1 ] && echo 1 || echo 0)"
g=$(plog 'gave up on'); poll; poll
check "give-up is logged once per PR update, not every poll" "$g" "$(plog 'gave up on')"

echo "== poller: going live does not replay the backlog"
before=$(jobs_n)
mkcfg false; poll
check "switch to live: older unread notifications are skipped" "$before" "$(jobs_n)"
p=$(plog 'predates going live'); poll
check "a PR that predates going live is logged once, not every poll" "$p" "$(plog 'predates going live')"
check "live_since recorded" 1 "$([ -s "$S/live_since" ] && echo 1 || echo 0)"
bump 11 2999-01-01T00:00:00Z
poll; check "a notification updated after going live runs" $((before + 1)) "$(jobs_n)"
check "and runs in live mode" false "$(tail -1 "$S/jobs.log" | jq '.[4]')"
bash "$T/../scripts/ctl.sh" replay >/dev/null; poll
check "replay includes the backlog (#12, #19, #20; #11 already handled, #18 has only ignored authors)" $((before + 4)) "$(jobs_n)"

echo "== poller: pause and lock"
: >"$S/handled.tsv"; : >"$S/seen.tsv"; n0=$(jobs_n)
touch "$S/paused"; poll; check "paused poll does nothing" "$n0" "$(jobs_n)"; rm "$S/paused"
mkdir "$S/poll.lock"; echo $$ >"$S/poll.lock/pid"; poll
check "live lock stops an overlapping poll" "$n0" "$(jobs_n)"
echo 999999 >"$S/poll.lock/pid"; : >"$S/poll.lock/x"; rm "$S/poll.lock/pid"; poll
check "lock with no pid yet is treated as live (grace period)" "$n0" "$(jobs_n)"
touch -t 200001010000 "$S/poll.lock"; poll
check "old lock with no pid is stale and does not block" $((n0 + 4)) "$(jobs_n)"
check "lock is released" no "$([ -e "$S/poll.lock" ] && echo yes || echo no)"
echo 999999 >"$W/pid"; mkdir "$S/poll.lock" && mv "$W/pid" "$S/poll.lock/pid"; : >"$S/handled.tsv"; : >"$S/seen.tsv"; poll
check "lock with a dead pid is stale" $((n0 + 8)) "$(jobs_n)"
jq 'map(if .id == "t2" then .subject.url = "https://api.github.com/repos/acme/app/pulls/99" else . end)' "$FIX/notifications.json" >"$W/x" && mv "$W/x" "$FIX/notifications.json"
: >"$S/handled.tsv"; : >"$S/seen.tsv"; n1=$(jobs_n); poll
check "one PR that cannot be fetched does not abort the poll" $((n1 + 4)) "$(jobs_n)"

echo "== poller: search is the primary source, notifications may be empty"
rm -f "$S/handled.tsv" "$S/failed.tsv" "$S/seen.tsv" "$S/live_since" "$S/mode"; rm -rf "$S/running"; mkdir -p "$S/running"
cp "$T/fixtures/notifications.json" "$FIX/notifications.json"
echo '[{"id":55,"state":"APPROVED","user":{"login":"me"},"commit_id":"jjj000"}]' >"$FIX/reviews-20.json"
n2=$(jobs_n); mkcfg true; FAKE_NOTIF_EMPTY=1 poll
check "no notifications at all: review #11, #19 and fix #12 still found; #20 already reviewed by me at this head" $((n2 + 3)) "$(jobs_n)"
check "re-requested but head unchanged: not reviewed again" 1 "$(plog 'skip acme/app#20: already reviewed this head')"
jq '.head.sha = "jjj111"' "$FIX/pr-20.json" >"$W/x" && mv "$W/x" "$FIX/pr-20.json"; bump 20
FAKE_NOTIF_EMPTY=1 poll; check "head changed since my review: reviewed again" $((n2 + 4)) "$(jobs_n)"

echo "== poller: once the feedback fix is done, a merge conflict is next"
jq '.mergeable_state = "dirty" | .base.sha = "bbb000"' "$FIX/pr-12.json" >"$W/x" && mv "$W/x" "$FIX/pr-12.json"
fk=$(grep '"fix","acme/app",12' "$S/jobs.log" | tail -1 | jq -r '.[5]'); echo "dry|$fk" >>"$S/handled.tsv"; bump 12
n3=$(jobs_n); FAKE_NOTIF_EMPTY=1 poll
check "fix already handled + PR dirty: a conflict job starts for #12" '"conflict" 12' "$([ "$(jobs_n)" -gt "$n3" ] && tail -1 "$S/jobs.log" | jq -r '"\"\(.[0])\" \(.[2])"')"
echo "== poller: then failing CI; at most 3 CI fixes per PR"
jq -n '{check_runs: [{status: "completed", conclusion: "failure"}]}' >"$W/ck-red2.json"
ck=$(tail -1 "$S/jobs.log" | jq -r '.[5]'); grep -qxF "dry|$ck" "$S/handled.tsv" || echo "dry|$ck" >>"$S/handled.tsv"; bump 12
n4=$(jobs_n); FAKE_CHECKS=$W/ck-red2.json FAKE_NOTIF_EMPTY=1 poll
check "fix and conflict handled + CI red: a CI fix job starts for #12" '"cifix" 12' "$([ "$(jobs_n)" -gt "$n4" ] && tail -1 "$S/jobs.log" | jq -r '"\"\(.[0])\" \(.[2])"')"
printf 'dry|cifix|acme/app|12|old1\ndry|cifix|acme/app|12|old2\n' >>"$S/handled.tsv"
jq '.head.sha = "ccc999"' "$FIX/pr-12.json" >"$W/x" && mv "$W/x" "$FIX/pr-12.json"; bump 12; rm -f "$S/notified"
n5=$(grep -c '"cifix","acme/app",12' "$S/jobs.log"); FAKE_CHECKS=$W/ck-red2.json FAKE_NOTIF_EMPTY=1 poll; bump 12; FAKE_CHECKS=$W/ck-red2.json FAKE_NOTIF_EMPTY=1 poll
check "after 3 CI fixes: no 4th CI job for #12, the user is told once" "$n5 1" "$(grep -c '"cifix","acme/app",12' "$S/jobs.log") $(grep -c 'PR #12 .*CI is still failing after 3 fix attempts' "$S/notified")"
echo "== poller: network blips are quiet, failed.tsv only lists active failures"
mkcfg true; rm -f "$S/notified" "$S/last_error_report" "$S/poll_failures"
for i in 1 2 3 4; do FAKE_GH_FAIL="GET user" poll >/dev/null 2>&1; done
check "4 polls in a row without gh api user: nothing reported, only logged" "0 4" "$(cat "$S/notified" 2>/dev/null | grep -c 'returned nothing') $(cat "$S/poll_failures")"
FAKE_GH_FAIL="GET user" poll >/dev/null 2>&1
check "the 5th consecutive failure is reported" 1 "$(grep -c 'returned nothing.*(5 polls in a row)' "$S/notified")"
rm -f "$S/fake/flaky"; FAKE_GH_FLAKY=2 poll >/dev/null 2>&1
check "two transient errors inside one poll are retried: it succeeds and the failure counter resets" "0" "$(cat "$S/poll_failures")"
rm -f "$S/notified" "$S/last_error_report" "$S/poll_failures"
FAKE_GH_FAIL="GET user" poll >/dev/null 2>&1; poll >/dev/null 2>&1
check "one failed poll followed by a good one: the counter is back to 0" 0 "$(cat "$S/poll_failures")"
: >"$S/seen.tsv"; bump 12; now=$(date +%s)
printf '1\tdry|cifix|acme/app|12|ccc999\n%s\tdry|cifix|acme/app|12|oldhead\n%s\tdry|review|acme/app|999|x\n%s\tdry|cifix|acme/app|12|ccc999\n' "$now" "$now" "$now" >"$S/failed.tsv"
FAKE_CHECKS=$W/ck-red2.json FAKE_NOTIF_EMPTY=1 poll
check "failed.tsv drops the old-key and over-age entries; a PR merely absent from the list keeps its entry" "$now	dry|review|acme/app|999|x
$now	dry|cifix|acme/app|12|ccc999" "$(cat "$S/failed.tsv")"
printf '%s\tdry|cifix|acme/app|12|ccc999\n' "$now" >"$S/failed.tsv"; bash "$T/../scripts/ctl.sh" status >"$W/status.txt"
check "status lists it once, as an active failure" 1 "$(grep -c '^  1x dry|cifix|acme/app|12|ccc999$' "$W/status.txt")"

echo "== poller: no jobs start while the claude session limit is active"
mkcfg true; : >"$S/seen.tsv"; : >"$S/handled.tsv"; : >"$S/failed.tsv"; n0=$(jobs_n); touch "$S/claude_limited"; poll
check "limit hit just now: no job starts" "$n0" "$(jobs_n)"
rm -f "$S/claude_limited"; : >"$S/seen.tsv"; poll
check "limit gone: jobs start again" 1 "$([ "$(jobs_n)" -gt "$n0" ] && echo 1 || echo 0)"

echo "== scheduler files keep jobs alive after poll.sh exits"
plist=$(bash "$T/../scripts/install-scheduler.sh" print-plist); unit=$(bash "$T/../scripts/install-scheduler.sh" print-unit)
check "launchd plist has AbandonProcessGroup=true" 1 "$(grep -c '<key>AbandonProcessGroup</key><true/>' <<<"$plist")"
check "systemd unit has KillMode=process" 1 "$(grep -c '^KillMode=process$' <<<"$unit")"
if command -v plutil >/dev/null; then check "plist is valid" 1 "$(plutil -lint - <<<"$plist" >/dev/null 2>&1 && echo 1 || echo 0)"; fi

# ======================================================================================
echo "== job.sh against a throwaway git repo with a fake claude"
rm -rf "$S" "$FIX"; mkdir -p "$S"; cp -R "$T/fixtures" "$FIX"; : >"$S/jobs.log"
O=$W/origin
git init -q -b main "$O"
mkdir -p "$O/.claude/rules" "$O/src" "$O/sub"
echo 'base conventions' >"$O/AGENTS.md"; echo 'claude md' >"$O/CLAUDE.md"; echo 'sub claude' >"$O/sub/CLAUDE.md"
echo 'rule one' >"$O/.claude/rules/r1.md"; echo '{"hooks":{}}' >"$O/.claude/settings.json"; echo '{}' >"$O/.mcp.json"
echo x >"$O/src/a.txt"
git -C "$O" add -A && git -C "$O" -c user.name=t -c user.email=t@t commit -q -m init
SHA=$(git -C "$O" rev-parse HEAD)
git -C "$O" branch feature-11 && git -C "$O" update-ref refs/pull/11/head HEAD
git clone -q "$O" "$W/clone"
git -C "$W/clone" remote set-url origin https://github.com/acme/app.git
git -C "$W/clone" config url."$O".insteadOf https://github.com/acme/app.git
git -C "$W/clone" config user.name t; git -C "$W/clone" config user.email t@t
jq --arg s "$SHA" '.head.sha = $s | .head.ref = "feature-11"' "$FIX/pr-11.json" >"$W/x" && mv "$W/x" "$FIX/pr-11.json"
jq -n --arg c "$W/clone" '{repos: {"acme/app": $c}, dry_run: false}' >"$PR_AUTOPILOT_CONFIG"; cp "$PR_AUTOPILOT_CONFIG" "$W/cfg0.json"
ev() { # ev <kind> <dry_run> [head]
  local key="review|acme/app|11|$SHA" who=alice cr=false
  [ "$1" = fix ] && { key="fix|acme/app|11|r901-v0-c5001-i0"; who=bob; cr=true; }
  [ "$1" = cifix ] && { key="cifix|acme/app|11|${3:-$SHA}"; who=CI; }
  [ "$1" = conflict ] && { key="conflict|acme/app|11|${3:-$SHA}|base"; who="the base branch"; }
  jq -n --arg k "$1" --argjson d "$2" --arg a "${ASSOC:-MEMBER}" --arg h "${3:-$SHA}" --arg key "$key" --arg who "$who" --argjson cr "$cr" \
    '{kind:$k, key:$key, repo:"acme/app", number:11, head:$h, branch:"feature-11", base:"main",
      title:"PR 11 title", url:"https://x/11", attempt:0, who:$who, cr:$cr, thread:"t1", reason:"x", author_assoc:$a, dry_run:$d}' >"$W/ev.json"
}
job() { bash "$T/../scripts/job.sh" "$W/ev.json"; }
reset() { rm -rf "$S/logs" "$S/fake" "$S/writes.log" "$S/handled.tsv" "$S/failed.tsv" "$S/notified" "$S/claude."*; }
allow() { awk '/^--allowedTools$/ {getline; print}' "$S/claude.args"; }
deny() { awk '/^--disallowedTools$/ {getline; print}' "$S/claude.args"; }
nwrites() { grep -c "$1" "$S/writes.log" 2>/dev/null || true; }

echo "-- review, dry-run"
reset; ev review true; FAKE_CLAUDE=review job
check "claude runs in the job's worktree" 1 "$(sed -n 1p "$S/claude.args" | grep -c "^$S/worktrees/acme_app-11-review-")"
for flag in --setting-sources --strict-mcp-config '{"disableAllHooks":true}' dontAsk --no-session-persistence "--add-dir"; do
  check "claude flag $flag" 1 "$(grep -cxF -- "$flag" "$S/claude.args")"
done
check "project settings, user settings and MCP are off (empty --setting-sources)" "" "$(awk '/^--setting-sources$/ {getline; print}' "$S/claude.args")"
check "review allow list is exactly Agent + the draft file" "Agent,Edit(/$(cat "$S/claude.jobdir")/draft.md)" "$(allow)"
check "no gh/shell/Skill/Bash allowed for review" 0 "$(allow | grep -cE 'Bash|Skill|gh ')"
check "gh, git and curl are denied" 3 "$(deny | tr ',' '\n' | grep -cE '^Bash\((gh|git|curl) \*\)$')"
check "checkout has no CLAUDE.md, AGENTS.md, .claude/ or .mcp.json (also nested)" 0 "$(grep -cE 'CLAUDE|AGENTS|\.mcp|\.claude' "$S/claude.cwdfiles")"
check "checkout still has the code" 1 "$(grep -c '^./src/a.txt$' "$S/claude.cwdfiles")"
check "base AGENTS.md is given as a plain data file" "base conventions" "$(cat "$(cat "$S/claude.jobdir")/conventions/AGENTS.md.txt")"
check "base .claude/rules is given as a data file, not hidden behind a leading dot" "rule one" "$(cat "$(cat "$S/claude.jobdir")/conventions/rules__r1.md.txt")"
check "job log records subagent calls, parallelism, turns, duration, cost" 1 "$(grep -c '^stats: agent_calls=3 max_agents_in_one_message=3 num_turns=5 duration_ms=1234 cost_usd=0.5$' "$S/logs/"*review.log)"
check "claude is asked for stream-json" 1 "$(grep -cxF stream-json "$S/claude.args")"
check "diff and reviews are pre-fetched" 1 "$([ -s "$(cat "$S/claude.jobdir")/diff.patch" ] && [ -s "$(cat "$S/claude.jobdir")/reviews.json" ] && echo 1 || echo 0)"
check "dry-run writes nothing to GitHub" 0 "$([ -e "$S/writes.log" ] && wc -l <"$S/writes.log" | tr -d ' ' || echo 0)"
check "a PR report is a window with Open PR that opens the PR link" 1 "$([ "$(uname)" = Darwin ] && grep -c 'buttons {"Close", "Open PR"}.*open location (item 2 of argv).* -- \[DRY RUN\] PR #11 (PR 11 title).* https://x/11$' "$S/notified" || echo 1)"
check "dry-run reports what it would have done" 1 "$(grep -c '\[DRY RUN\] PR #11 (PR 11 title): alice asked you to review it. I would have posted APPROVE: No blockers found. (nothing was posted)' "$S/notified")"
check "success is recorded as handled" 1 "$(grep -cxF "dry|review|acme/app|11|$SHA" "$S/handled.tsv")"
check "worktree is cleaned up" 0 "$(git -C "$W/clone" worktree list | grep -c pr-autopilot)"

echo "-- review, live: the script posts, pinned to the head commit, and verifies"
reset; ev review false; FAKE_CLAUDE=review-rc job
check "one review POST, pinned to commit_id, with the model's verdict" "POST repos/acme/app/pulls/11/reviews event=REQUEST_CHANGES commit_id=$SHA" "$(cat "$S/writes.log" | grep POST)"
check "notification marked read only after success" 1 "$(grep -c 'PATCH notifications/threads/t1' "$S/writes.log")"
check "report says verified" 1 "$(grep -c "I posted REQUEST_CHANGES (verified on GitHub, review 777, commit ${SHA:0:7}): src/a.txt:2" "$S/notified")"
FAKE_CLAUDE=review job
check "never double-posts for the same head" 1 "$(nwrites 'POST .*reviews')"
check "and says so" 1 "$(grep -c 'I did not post: I already reviewed this commit' "$S/notified")"

echo "-- review: a PR too large for one diff call falls back to per-file patches"
cat >"$FIX/files-11.json" <<'J'
[{"filename":"src/a.txt","status":"modified","patch":"@@ -1 +1,2 @@\n x\n+y"}]
[{"filename":"src/big.txt","status":"modified"}]
J
reset; ev review true; FAKE_DIFF_TOO_LARGE=1 FAKE_CLAUDE=review job
jd=$(cat "$S/claude.jobdir")
check "job proceeds and succeeds" 1 "$(grep -c "dry|review|acme/app|11|$SHA" "$S/handled.tsv")"
check "model input has the per-file patch (second page too)" 1 "$(grep -c '^+y$' "$jd/diff.patch")"
check "a file without a patch is listed with a pointer to the checkout" 1 "$(grep -A2 '^diff --git a/src/big.txt' "$jd/diff.patch" | grep -c 'patch too large.*checkout')"
check "log records the fallback path" 1 "$(grep -c '^diff: per-file patches from the files API (2 files, 1 without a patch)' "$S/logs/"*review.log)"
cat >"$FIX/files-11.json" <<'J'
[{"filename":"src/a.txt","status":"modified","patch":"@@ -1 +1,2 @@\n x\n+y"},{"filename":"src/e\nvil\r.txt","status":"added","patch":"@@ -0,0 +1 @@\n+z"}]
J
jq '.changed_files = 3001' "$FIX/pr-11.json" >"$W/x" && mv "$W/x" "$FIX/pr-11.json"
reset; ev review true; FAKE_DIFF_TOO_LARGE=1 FAKE_CLAUDE=review job
jd=$(cat "$S/claude.jobdir")
check "fewer files than changed_files: loud warning at the top of diff.patch and in the log" "1 1" "$(head -1 "$jd/diff.patch" | grep -c 'WARNING: PARTIAL DIFF.*2 of 3001') $(grep -c '^WARNING: partial diff, 2 of 3001' "$S/logs/"*review.log)"
check "newline and CR in a filename cannot fake diff lines" "2 1" "$(grep -c '^diff --git' "$jd/diff.patch") $(grep -c '^diff --git a/src/e vil .txt b/src/e vil .txt$' "$jd/diff.patch")"
jq 'del(.changed_files)' "$FIX/pr-11.json" >"$W/x" && mv "$W/x" "$FIX/pr-11.json"
reset; ev review true; FAKE_CLAUDE=review job
check "small PR keeps the single-call path" 1 "$(grep -c '^diff: single call (gh pr diff)' "$S/logs/"*review.log)"
echo "-- review: the user's own review skills add one parallel pass each"
mkdir -p "$W/skills/money-lens"; echo 'Check money rounding.' >"$W/skills/money-lens/SKILL.md"
jq --arg p "$W/skills/money-lens/SKILL.md" '. + {review_skills: [$p]}' "$W/cfg0.json" >"$PR_AUTOPILOT_CONFIG"
reset; ev review false; FAKE_CLAUDE=review job
check "3 passes are not enough with one extra skill: fails, nothing posted" "1 0" "$(grep -c 'review needs 4 parallel passes but only 3' "$S/notified") $(cat "$S/writes.log" 2>/dev/null | grep -c POST)"
check "the skill is copied into the job dir under its folder name" "Check money rounding." "$(cat "$(cat "$S/claude.jobdir")/review-skills/1-money-lens.md")"
reset; ev review false; FAKE_AGENTS=4 FAKE_CLAUDE=review job
check "4 passes with one extra skill: posted" 1 "$(cat "$S/writes.log" | grep -c 'event=APPROVE')"
jq '. + {review_skills: ["/no/such/SKILL.md"]}' "$W/cfg0.json" >"$PR_AUTOPILOT_CONFIG"
reset; ev review false; FAKE_CLAUDE=review job
check "a missing review skill file fails loudly before claude runs" "1 0" "$(grep -c "review_skills entry '/no/such/SKILL.md' is not a readable file" "$S/notified") $([ -e "$S/claude.args" ] && echo 1 || echo 0)"
cp "$W/cfg0.json" "$PR_AUTOPILOT_CONFIG"
echo "-- review: bad drafts and failures are loud, nothing is posted"
reset; ev review false; FAKE_CLAUDE=review-long job
check "over 150 words: asks for a shorter draft once, then posts the shortened review" "1 1" "$(cat "$S/logs/"*review.log | grep -c 'asking for a shorter one') $(cat "$S/writes.log" | grep -c 'event=APPROVE')"
check "usage includes the follow-up (0.5 + 0.05)" 1 "$(cat "$S/logs/"*review.log | grep -c '^usage: total_cost_usd=0.5500$')"
reset; ev review false; FAKE_SHORTEN_FAIL=1 FAKE_CLAUDE=review-long job
check "still over after the follow-up fails (attempt 1 of 3) and posts nothing" "1 1 0" "$(grep -c 'FAILED (attempt 1 of 3): draft body is 200 words even after asking' "$S/notified") $(grep -c 'live|review' "$S/failed.tsv") $(cat "$S/writes.log" 2>/dev/null | grep -c POST)"
reset; jq '. + {max_cost_usd_per_job: 0.1}' "$W/cfg0.json" >"$PR_AUTOPILOT_CONFIG"; ev review false; FAKE_CLAUDE=review job
check "cost over max_cost_usd_per_job is reported but nothing is stopped" "1 1" "$(grep -c 'Cost warning: this job cost about $0.5000, over max_cost_usd_per_job=0.1' "$S/notified") $(cat "$S/writes.log" | grep -c 'event=APPROVE')"
cp "$W/cfg0.json" "$PR_AUTOPILOT_CONFIG"
FAKE_CLAUDE=review-badverdict job; check "bad VERDICT line fails" 1 "$(grep -c "must be 'VERDICT: APPROVE'" "$S/notified")"
FAKE_CLAUDE=none job; check "missing draft fails" 1 "$(grep -c 'wrote no draft.md' "$S/notified")"
FAKE_CLAUDE=review-badverdict job
check "third failure says giving up" 1 "$(grep -c 'attempt 3 of 3, giving up' "$S/notified")"
reset; FAKE_CLAUDE=crash job; check "claude crash is reported" 1 "$(grep -c 'FAILED (attempt 1 of 3): claude exited with status 1' "$S/notified")"
reset; ev review false; FAKE_AGENTS=2 FAKE_CLAUDE=review job
check "fewer than three review passes fails loudly, nothing posted, retry recorded" "1 1 0" "$(grep -c 'FAILED (attempt 1 of 3): review needs 3 parallel passes but only 2 subagent call(s) ran' "$S/notified") $(grep -c 'live|review' "$S/failed.tsv") $(cat "$S/writes.log" 2>/dev/null | grep -c POST)"
reset; ev review false deadbeef; FAKE_CLAUDE=review job
check "head moved before start: quiet skip, no failure, no post" "0 0" "$(cat "$S/notified" 2>/dev/null | wc -l | tr -d ' ') $([ -e "$S/failed.tsv" ] && echo 1 || echo 0)"
reset; touch "$S/paused"; ev review false; FAKE_CLAUDE=review job; rm "$S/paused"
check "pause aborts the job before claude runs, silently" "0 0" "$(cat "$S/notified" 2>/dev/null | wc -l | tr -d ' ') $([ -e "$S/claude.args" ] && echo 1 || echo 0)"

echo "-- transient GitHub errors: retried inside the call, and never burn an attempt"
reset; ev review false; FAKE_GH_FLAKY=2 FAKE_CLAUDE=review job
check "two transient errors on the first gh calls: the job still succeeds, no failure recorded" "1 0" "$(grep -c 'live|review' "$S/handled.tsv") $([ -e "$S/failed.tsv" ] && wc -l <"$S/failed.tsv" | tr -d ' ' || echo 0)"
for m in "read: can't assign requested address" "read: connection reset by peer" "dial tcp: i/o timeout" "gh: Bad Gateway (HTTP 502)" "gh: Service Unavailable (HTTP 503)" "gh: Gateway Timeout (HTTP 504)" "You have exceeded a secondary rate limit"; do
  reset; ev review false; FAKE_GH_FLAKY=1 FAKE_GH_FLAKY_MSG="$m" FAKE_CLAUDE=review job
  check "retried: $m" 1 "$(grep -c 'live|review' "$S/handled.tsv")"
done
reset; rm -f "$S/transient.tsv"; ev review false; FAKE_GH_FLAKY=99 FAKE_CLAUDE=review job
check "GitHub down through all retries: not an attempt, no report, noted for the next poll" "0 0 1" \
  "$([ -e "$S/failed.tsv" ] && wc -l <"$S/failed.tsv" | tr -d ' ' || echo 0) $(cat "$S/notified" 2>/dev/null | wc -l | tr -d ' ') $(wc -l <"$S/transient.tsv" | tr -d ' ')"
reset; ev review false; FAKE_GH_FLAKY=99 FAKE_GH_FLAKY_MSG="HTTP 404 Not Found" FAKE_CLAUDE=review job
check "a non-transient error is not retried and burns an attempt" 1 "$(grep -c 'live|review' "$S/failed.tsv")"
reset; ev review false; FAKE_CLAUDE=limit job
check "claude session limit: no attempt burned, no failure report, job starts paused" "0 0 1" \
  "$([ -e "$S/failed.tsv" ] && wc -l <"$S/failed.tsv" | tr -d ' ' || echo 0) $(cat "$S/notified" 2>/dev/null | wc -l | tr -d ' ') $([ -e "$S/claude_limited" ] && echo 1 || echo 0)"
rm -f "$S/claude_limited"

reset; rm -f "$S/failed.tsv"
for i in 1 2 3 4 5; do printf '%s\tlive|review|acme/app|11|%s\n' "$(date +%s)" "$SHA" >>"$S/transient.tsv"; done
ev review false; FAKE_CLAUDE=limit job
check "session limit cannot loop forever: after 5 unpaid runs in a day it burns an attempt" 1 "$(grep -c 'live|review' "$S/failed.tsv")"
rm -f "$S/claude_limited" "$S/transient.tsv"
reset; ev review false; FAKE_CLAUDE=review-limit-text job
check "the phrase inside tool results/PR content is not a session limit: normal run, no pause" "1 0" "$(grep -c 'live|review' "$S/handled.tsv") $([ -e "$S/claude_limited" ] && echo 1 || echo 0)"
echo "-- a write the server applied before answering 502 is never sent twice"
reset; rm -f "$S/posted-comments.json"; ev review false; FAKE_WRITE_502=1 FAKE_CLAUDE=review job
check "review: POST answered 502 but applied: read back, exactly one review, success" "1 1" "$(nwrites 'POST .*reviews') $(grep -c 'live|review' "$S/handled.tsv")"
(
  . "$T/../scripts/lib.sh"; mkdir -p "$S/fake"
  rm -f "$S/fake/flaky"; FAKE_GH_FLAKY=2 gh api -X POST repos/acme/app/issues/1/comments -f body=x >/dev/null 2>&1; rc=$?
  check "gh() does not retry a POST on a 502 (one call, it fails)" "1 1" "$rc $(cat "$S/fake/flaky")"
  rm -f "$S/fake/flaky"; FAKE_GH_FLAKY=2 FAKE_GH_FLAKY_MSG="You have exceeded a secondary rate limit" gh api -X POST repos/acme/app/issues/1/comments -f body=x >/dev/null 2>&1; rc=$?
  check "gh() does retry a POST on a secondary rate limit" "0 2" "$rc $(cat "$S/fake/flaky")"
  rm -f "$S/fake/flaky"; FAKE_GH_FLAKY=2 gh api -X post repos/acme/app/issues/1/comments >/dev/null 2>&1; rc=$?
  check "gh() classifies a lowercase -X post as a write: no retry on 502" "1 1" "$rc $(cat "$S/fake/flaky")"
  rm -f "$S/fake/flaky"; FAKE_GH_FLAKY=2 gh api repos/acme/app/pulls/11 >/dev/null 2>&1; rc=$?
  check "gh() still retries a read on a 502-class error" "0 2" "$rc $(cat "$S/fake/flaky")"
  echo "$pass $fail" >"$W/counts"
)
read -r pass fail <"$W/counts"

echo "-- fix, dry-run"
reset; ev fix true; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix job
check "fix allow list: edits in worktree + result file + test commands, no gh, no git" 0 "$(allow | grep -cE 'gh |git |Skill')"
check "fix may edit inside the worktree" 1 "$(allow | tr ',' '\n' | grep -c "^Edit(/$S/worktrees/acme_app-11-fix-.*/\*\*)$")"
check "dry-run does not push" "$SHA" "$(git -C "$O" rev-parse refs/heads/feature-11)"
check "dry-run posts nothing" 0 "$([ -e "$S/writes.log" ] && wc -l <"$S/writes.log" | tr -d ' ' || echo 0)"
check "dry-run report" 1 "$(grep -c 'I would have fixed: the missing null check (1 files), pushed, replied on 1 thread(s), re-requested review from @bob' "$S/notified")"

echo "-- fix, live: the script commits, pushes the PR branch only, replies, re-requests, verifies"
reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix job
new=$(git -C "$O" rev-parse refs/heads/feature-11)
check "PR branch advanced by one commit on top of the old head" "$SHA" "$(git -C "$O" rev-parse "$new^")"
check "commit message from result.json, @mentions defanged" 'Add null check `@everyone`' "$(git -C "$O" log -1 --format=%s "$new")"
check "no other ref was touched (no force, no new branches)" "refs/heads/feature-11 refs/heads/main refs/pull/11/head" \
  "$(git -C "$O" for-each-ref --format='%(refname)' | sort | tr '\n' ' ' | sed 's/ $//')"
check "agent config files were not deleted by the commit" 0 "$(git -C "$O" diff --name-status "$SHA" "$new" | grep -c '^D')"
check "reply posted on the thread with the real short sha" "POST repos/acme/app/pulls/11/comments/5001/replies body=Fixed in ${new:0:7}, thanks "'`@bob`.' "$(grep 'replies' "$S/writes.log")"
check "re-request only for actual reviewers (stranger dropped)" "POST repos/acme/app/pulls/11/requested_reviewers bob" "$(grep requested_reviewers "$S/writes.log")"
check "report states verified facts" 1 "$(grep -c "I fixed the missing null check, pushed ${new:0:7}, replied on 1 thread(s), re-requested review from @bob (verified on GitHub)" "$S/notified")"
echo "-- fix: a reviewer who requested changes is re-requested even when a point was declined"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-decline job
check "bob (latest review CHANGES_REQUESTED) re-requested although the model listed nobody" "POST repos/acme/app/pulls/11/requested_reviewers bob" "$(grep requested_reviewers "$S/writes.log")"
echo "-- fix: malformed result writes nothing"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false
FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-badreply job
check "reply to a nonexistent comment id is rejected before any write" "1 0" "$(grep -c 'malformed' "$S/notified") $([ -e "$S/writes.log" ] && wc -l <"$S/writes.log" | tr -d ' ' || echo 0)"
check "and the branch is untouched" "$SHA" "$(git -C "$O" rev-parse refs/heads/feature-11)"
echo "-- fix: replies may not promise or defer what the job does not do (PR 1554)"
AR=$T/../skills/address-review/SKILL.md
for rule in 'Check every promise before you write the result' 'If you cannot record it, do not defer' \
  'the cheap code option and its rough size' 'quotes the description' '"done_by": "pr_body"' '{{deferral:0}}'; do
  check "address-review prompt has the rule: $rule" 1 "$(grep -qF -- "$rule" "$AR" && echo 1 || echo 0)"
done
nw() { [ -e "$S/writes.log" ] && wc -l <"$S/writes.log" | tr -d ' ' || echo 0; }
reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-promise-unmet job
check "an unbacked 'I will correct the PR description' blocks posting, nothing written" "1 0" "$(grep -c 'posting blocked.*reply 1 promises an action' "$S/notified") $(nw)"
reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-nothing job
check "PR 1623: an empty result writes nothing (no issue titled null, no reply) and does not fail" "0 0" "$(nwrites 'repos/') $(grep -c 'FAILED' "$S/notified")"
reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-blank-deferral job
check "a blank deferral title is refused before any write" "1 0" "$(grep -c 'malformed pr_body, escalate, deferrals or promises' "$S/notified") $(nw)"
reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-blank-reply job
check "a blank reply body is refused before any write" "1 0" "$(grep -c 'result.json is malformed' "$S/notified") $(nw)"
reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-defer-unrecorded job
check "deferring to another PR without a recorded deferral blocks posting" "1 0" "$(grep -c 'posting blocked.*reply 1 defers the point but links no recorded deferral' "$S/notified") $(nw)"
reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-defer-foreign job
check "a deferral comment goes only to the user's own open PR" "1 0" "$(grep -c 'deferral target #13 is not an open PR of yours' "$S/notified") $(nw)"
reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-docsonly job
check "docs-only answer to a changes request: the owner is told even if the model did not escalate" 1 "$(grep -c 'verified on GitHub). NEEDS YOU: A reviewer requested changes and I changed no code' "$S/notified")"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-curly job
check "a promise written with a curly apostrophe (I’ll) is caught too" "1 0" "$(grep -c 'posting blocked.*reply 1 promises an action' "$S/notified") $(nw)"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-many-deferrals job
check "more than 3 deferrals: refused, owner asked, nothing written" "1 0" "$(grep -c 'refusing 4 deferrals (max 3), nothing written. NEEDS YOU' "$S/notified") $(nw)"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_BODY_RACE=1 FAKE_CLAUDE=fix-1554-done job
check "description edited during the job: not overwritten, nothing pushed or posted, owner told" "1 0 $SHA" "$(grep -c 'PR description changed while the job ran.*NEEDS YOU' "$S/notified") $(nw) $(git -C "$O" rev-parse refs/heads/feature-11)"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_BODY_CRLF=1 FAKE_CLAUDE=fix-1554-done job
check "description read back with CRLF and trailing space still verifies" 1 "$(grep -c 'updated the PR description.*(verified on GitHub)' "$S/notified")"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false
FAKE_HEAD_REPO=$O FAKE_GH_FAIL="POST repos/acme/app/pulls/11/comments/5001/replies" FAKE_CLAUDE=fix-1554-done job
check "a failure after the gate still tells the owner NEEDS YOU" 1 "$(grep -c 'PARTLY DONE, then FAILED: after the push: reply 1 failed;.*NEEDS YOU: My call: docs now' "$S/notified")"
echo "-- read-back never mistakes an older or other-thread comment of mine for the write that just failed"
for case in "2020-01-01T00:00:00Z 5001" "2999-01-01T00:00:00Z 9999"; do
  git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false; mkdir -p "$S/fake"
  jq -n --arg t "${case% *}" --argjson r "${case#* }" '[{id: 1, user: {login: "me"}, body: "Fixed one, declined the other: out of scope.", created_at: $t, in_reply_to_id: $r}]' >"$S/fake/posted-comments.json"
  FAKE_HEAD_REPO=$O FAKE_GH_FAIL="POST repos/acme/app/pulls/11/comments/5001/replies" FAKE_CLAUDE=fix-decline job
  check "identical reply (created/thread: $case) is not taken as posted: the job fails loudly" 1 "$(grep -c 'FAILED: after the push: reply 1 failed' "$S/notified")"
done
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false
FAKE_HEAD_REPO=$O FAKE_GH_FAIL="POST repos/acme/app/issues" FAKE_CLAUDE=fix-two-deferrals job
check "a failed second deferral lists the one already recorded, no reply posted" "1 0" "$(grep -c 'FAILED: recording deferral 1 failed, no reply was posted. Already recorded, clean up if needed: https://github.com/repos/acme/app/issues/12/comments#c889. NEEDS YOU: Two deferred points' "$S/notified") $(nwrites replies)"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-defer-issue job
check "a deferral without an own target PR becomes an issue that the reply links" "1 1" "$(grep -c '^POST repos/acme/app/issues title=Enforce uniqueness body=From review.' "$S/writes.log") $(grep -c 'replies body=Out of this PR, tracked in https://github.com/acme/app/issues/99\.' "$S/writes.log")"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; rm -f "$S/posted-comments.json"; ev fix false; FAKE_WRITE_502=1 FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-defer-issue job
check "issue and reply POSTs answered 502 but applied: each written exactly once (read back, not re-sent)" "1 1" "$(nwrites '^POST repos/acme/app/issues title') $(nwrites 'replies body=')"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix true; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-1554-done job
check "dry-run says it would fix the description and record the deferral, and escalates" 1 "$(grep -c 'updated the PR description, recorded 1 deferral(s), replied on 1 thread(s).*NEEDS YOU: My call: docs now' "$S/notified")"
reset; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-1554-done job
check "the PR description is edited on the user's own PR" "PATCH repos/acme/app/pulls/11 body=Adds the limit. It does not enforce uniqueness yet." "$(grep '^PATCH repos' "$S/writes.log")"
check "the deferral is recorded on the target PR, linking back" "1 1" "$(grep -c '^POST repos/acme/app/issues/12/comments body=Carry over from #11' "$S/writes.log") $(grep -cx 'Deferred from the review of #11: https://x/11' "$S/writes.log")"
check "the reply links the recorded deferral" 1 "$(grep -c 'replies body=.*recorded there: https://github.com/repos/acme/app/issues/12/comments#c889\.' "$S/writes.log")"
check "the writes happen in order: push, description, deferral, reply" "PATCH POST POST POST" "$(grep -oE '^(PATCH|POST) repos/[^ ]*' "$S/writes.log" | head -4 | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
check "the report carries the owner escalation" 1 "$(grep -c 'updated the PR description, recorded 1 deferral(s) (https://github.com/repos/acme/app/issues/12/comments#c889).*verified on GitHub). NEEDS YOU: My call: docs now, constraint in #12. Cheap code option' "$S/notified")"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"


echo "== conflict: merge the base into the PR branch, resolve, push"
# A real conflict: main and feature-11 both change the same file. Only the throwaway origin $O moves.
mkconflict() { # mkconflict <file>: fresh conflicting commits on main and feature-11; sets PRH and MAINH
  git -C "$O" checkout -q main && git -C "$O" reset -q --hard "$SHA"
  printf 'main side\n' >"$O/$1"; echo keep >"$O/src/other.txt"; git -C "$O" add -A && git -C "$O" -c user.name=t -c user.email=t@t commit -q -m main-change
  MAINH=$(git -C "$O" rev-parse HEAD)
  git -C "$O" checkout -q -B feature-11 "$SHA"; printf 'pr side\n' >"$O/$1"; git -C "$O" add -A
  git -C "$O" -c user.name=t -c user.email=t@t commit -q -m pr-change; PRH=$(git -C "$O" rev-parse HEAD)
  git -C "$O" update-ref refs/pull/11/head "$PRH"; git -C "$O" checkout -q main
}
mkconflict src/a.txt; reset; ev conflict true "$PRH"; FAKE_HEAD_REPO=$O FAKE_CLAUDE=conflict job
check "dry-run: resolved but nothing pushed, says what it would do" "1 $PRH" "$(grep -c 'I would have merged main into your branch and resolved conflicts in 1 file(s) (src/a.txt): kept both lines and pushed (nothing was pushed)' "$S/notified") $(git -C "$O" rev-parse feature-11)"
check "conflict job: edits only, no shell, no git" 0 "$(allow | grep -cE 'Bash|gh |git ')"
reset; ev conflict false "$PRH"; FAKE_HEAD_REPO=$O FAKE_CLAUDE=conflict-stray job
new=$(git -C "$O" rev-parse feature-11)
check "live: the PR branch gets a merge commit of the PR head and main" "$PRH $MAINH" "$(git -C "$O" log -1 --format='%P' "$new")"
check "the resolved file is what was committed" "main side|pr side" "$(git -C "$O" show "$new:src/a.txt" | paste -sd'|' -)"
check "a non-conflicted file the model touched is put back" keep "$(git -C "$O" show "$new:src/other.txt")"
check "report: merged, resolved, pushed, verified" 1 "$(grep -c "I merged main into your branch and resolved conflicts in 1 file(s) (src/a.txt): kept both lines, pushed ${new:0:7} (verified on GitHub)" "$S/notified")"
mkconflict src/a.txt; reset; ev conflict false "$PRH"; FAKE_HEAD_REPO=$O FAKE_CLAUDE=conflict-markers job
check "markers left: fails loudly, nothing pushed" "1 $PRH" "$(grep -c 'conflict markers or broken files left after resolving: src/a.txt' "$S/notified") $(git -C "$O" rev-parse feature-11)"
reset; ev conflict false "$PRH"; FAKE_HEAD_REPO=$O FAKE_CLAUDE=conflict-unresolved job
check "a real disagreement goes to the user: merge aborted, nothing pushed, handled" "1 $PRH 1" "$(grep -c 'I did not resolve the merge conflicts: src/a.txt: both sides change the rule differently. Please merge main in by hand' "$S/notified") $(git -C "$O" rev-parse feature-11) $(grep -c 'live|conflict' "$S/handled.tsv")"
if command -v sandbox-exec >/dev/null; then
  mkconflict src/a.txt; reset; jq '. + {run_local_tests_UNSAFE: {"acme/app": ["false"]}}' "$W/cfg0.json" >"$PR_AUTOPILOT_CONFIG"
  ev conflict false "$PRH"; FAKE_HEAD_REPO=$O FAKE_CLAUDE=conflict job
  check "opt-in local tests run before a conflict merge is pushed; a failure stops the push" "1 $PRH" "$(grep -c "local test command 'false' failed" "$S/notified") $(git -C "$O" rev-parse feature-11)"
  cp "$W/cfg0.json" "$PR_AUTOPILOT_CONFIG"
fi
mkconflict AGENTS.md; reset; rm -f "$S/claude.args"; ev conflict false "$PRH"; FAKE_HEAD_REPO=$O FAKE_CLAUDE=conflict job
check "a conflict in agent config is never given to the model" "1 0 $PRH" "$(grep -c 'these need you: AGENTS.md (agent config)' "$S/notified") $([ -e "$S/claude.args" ] && echo 1 || echo 0) $(git -C "$O" rev-parse feature-11)"
git -C "$O" checkout -q main && git -C "$O" reset -q --hard "$SHA"; git -C "$O" update-ref refs/heads/feature-11 "$SHA"; git -C "$O" update-ref refs/pull/11/head "$SHA"

echo "== failing CI on the user's own PR: fix, re-run once, or hand over"
jq -n '{check_runs: [
  {id: 777, name: "Frontend Tests", status: "completed", conclusion: "failure", app: {slug: "github-actions"},
   details_url: "https://github.com/acme/app/actions/runs/555/job/777", output: {title: "1 test failed", summary: "", text: ""}},
  {id: 778, name: "Lint", status: "completed", conclusion: "success", app: {slug: "github-actions"},
   details_url: "https://github.com/acme/app/actions/runs/555/job/778", output: {}}]}' >"$W/checks-red.json"
reset; ev cifix true; FAKE_CHECKS=$W/checks-red.json FAKE_HEAD_REPO=$O FAKE_CLAUDE=cifix-fix job
jd=$(cat "$S/claude.jobdir")
check "the model gets the failing check (only) and its job log" "1 Frontend Tests 1" "$(jq -r 'length, .[0].name' "$jd/ci/failed.json" | paste -sd' ' -) $(grep -c 'FAIL src/a.test.ts' "$jd"/ci/1-Frontend_Tests.log)"
check "failed.json names the exact log path, so the model never guesses file names" 1 "$(grep -c 'FAIL src/a.test.ts' "$(jq -r '.[0].log' "$jd/ci/failed.json")")"
check "CI fix job: edits only, no shell, no git" 0 "$(allow | grep -cE 'Bash|gh |git ')"
check "dry-run: says what it would push, pushes nothing" "1 $SHA" "$(grep -c 'I would have fixed the failing CI: the test expected the old label (1 files) and pushed (nothing was pushed)' "$S/notified") $(git -C "$O" rev-parse feature-11)"
reset; ev cifix false; FAKE_CHECKS=$W/checks-red.json FAKE_HEAD_REPO=$O FAKE_CLAUDE=cifix-fix job
new=$(git -C "$O" rev-parse feature-11)
check "live fix: one commit on the PR branch with the listed file only" "$SHA src/a.txt" "$(git -C "$O" rev-parse "$new^") $(git -C "$O" diff --name-only "$SHA" "$new")"
check "and the report says pushed and verified" 1 "$(grep -c "I fixed the failing CI: the test expected the old label, pushed ${new:0:7} (verified on GitHub)" "$S/notified")"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"
reset; ev cifix false; FAKE_CHECKS=$W/checks-red.json FAKE_HEAD_REPO=$O FAKE_CLAUDE=cifix-rerun job
check "flaky: re-runs the failed jobs of that run once, pushes nothing" "1 $SHA 1" "$(grep -c 'POST repos/acme/app/actions/runs/555/rerun-failed-jobs' "$S/writes.log") $(git -C "$O" rev-parse feature-11) $(grep -c 'I re-ran the failed CI jobs once' "$S/notified")"
reset; ev cifix false; FAKE_CHECKS=$W/checks-red.json FAKE_HEAD_REPO=$O FAKE_CLAUDE=cifix-none job
check "not fixable here: hands over, writes nothing" "1 0" "$(grep -c 'I did not fix the failing CI: a deploy secret is missing in CI. This one needs you' "$S/notified") $(cat "$S/writes.log" 2>/dev/null | grep -c POST)"
reset; ev cifix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=cifix-fix job
check "CI is green by the time the job runs: quiet skip, nothing pushed" "0 $SHA" "$(cat "$S/notified" 2>/dev/null | wc -l | tr -d ' ') $(git -C "$O" rev-parse feature-11)"

echo "== safety: fix job has no shell, commits only listed files"
reset_fix() { git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; rm -f "$S/logs/"*; }
reset_fix; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix job
check "fix allow list has no Bash at all (default)" 0 "$(allow | grep -c Bash)"
new=$(git -C "$O" rev-parse refs/heads/feature-11)
check "only the file listed in result.json is committed, never git add -A" "src/a.txt" "$(git -C "$O" diff --name-only "$SHA" "$new")"
reset_fix; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-many job
check "more replies than open human comments is refused before any write" "1 0" "$(grep -c 'only 1 open human comments' "$S/notified") $(cat "$S/writes.log" 2>/dev/null | grep -c POST)"
cp "$PR_AUTOPILOT_CONFIG" "$W/cfg.bak"
optin() { jq --argjson c "$1" '. + {run_local_tests_UNSAFE: {"acme/app": $c}}' "$W/cfg.bak" >"$PR_AUTOPILOT_CONFIG"; }
reset_fix; optin '["ls"]'; ev fix true; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix job
check "opt-in tests never run in dry-run" 0 "$(cat "$S/logs/"*fix.log | grep -c 'running sandboxed')"
if command -v sandbox-exec >/dev/null; then
  cp "$W/cfg.bak" "$PR_AUTOPILOT_CONFIG"; reset_fix; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix job
  check "no opt-in, no local tests" 0 "$(cat "$S/logs/"*fix.log | grep -c 'running sandboxed')"
  reset_fix; optin '["ls"]'; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix job
  check "opted-in exact command runs sandboxed and the job still succeeds" "1 1" "$(cat "$S/logs/"*fix.log | grep -c 'running sandboxed: ls') $(grep -c 'verified on GitHub' "$S/notified")"
  rm -f "$HOME/ap-test-outside"; reset_fix; optin "[\"touch $HOME/ap-test-outside\"]"; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix job
  check "sandbox blocks writes outside the checkout; failing tests stop the job before any commit" "1 $SHA no" \
    "$(grep -c 'local test command .* failed' "$S/notified") $(git -C "$O" rev-parse refs/heads/feature-11) $([ -e "$HOME/ap-test-outside" ] && echo yes || echo no)"
  rm -f "$HOME/ap-test-outside"
fi
for bad in 'npx vitest' 'ls *' 'go test -exec foo ./...'; do
  reset_fix; optin "[\"$bad\"]"; ev fix false; FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix job
  check "unsafe test command refused: $bad" "1 $SHA" "$(grep -c 'refusing unsafe local test command\|sandbox-exec is not available' "$S/notified") $(git -C "$O" rev-parse refs/heads/feature-11)"
done
cp "$W/cfg.bak" "$PR_AUTOPILOT_CONFIG"; git -C "$O" update-ref refs/heads/feature-11 "$SHA"

echo "== safety: only trusted feedback starts a fix, stale notifications do not start a review"
cls() { # cls <pr> <reviews> <comments> <issue> <reason> <via_search>
  jq -n -c -f "$T/../scripts/classify.jq" --arg me me --arg reason "$5" --arg repo acme/app --argjson ignore '[]' \
    --argjson trusted "${TRUSTED:-[]}" --argjson via_search "$6" --argjson allow_forks false --argjson review_enabled true \
    --argjson fix_enabled true --argjson conflict_enabled "${CONFLICT:-true}" --argjson ci_enabled "${CI_ON:-true}" --slurpfile pr "$1" --slurpfile reviews "$2" --slurpfile comments "$3" --slurpfile issue "$4" --slurpfile checks "${CHECKS:-$W/nochecks.json}"
}
echo '[]' >"$W/empty.json"
echo '{"check_runs": []}' >"$W/nochecks.json"
for assoc in NONE CONTRIBUTOR FIRST_TIME_CONTRIBUTOR; do
  echo "[{\"id\":9,\"user\":{\"login\":\"rando\"},\"author_association\":\"$assoc\",\"body\":\"please add x\"}]" >"$W/c.json"
  check "feedback from a $assoc author is ignored (and counted)" "nothing to address 1" "$(cls "$FIX/pr-18.json" "$W/empty.json" "$W/c.json" "$W/empty.json" author true | jq -r '"\(.skip) \(.untrusted)"')"
done
for assoc in OWNER MEMBER COLLABORATOR; do
  echo "[{\"id\":9,\"user\":{\"login\":\"pal\"},\"author_association\":\"$assoc\",\"body\":\"please add x\"}]" >"$W/c.json"
  check "feedback from a $assoc starts a fix" fix "$(cls "$FIX/pr-18.json" "$W/empty.json" "$W/c.json" "$W/empty.json" author true | jq -r .kind)"
done
echo '[{"id":9,"user":{"login":"rando"},"author_association":"NONE","body":"x"}]' >"$W/c.json"
jq '.mergeable_state = "dirty" | .base.sha = "bbb000"' "$FIX/pr-18.json" >"$W/pr-dirty.json"
check "own PR with a merge conflict and no feedback: a conflict job keyed on head and base" "conflict conflict|acme/app|18|hhh888|bbb000" "$(cls "$W/pr-dirty.json" "$W/empty.json" "$W/empty.json" "$W/empty.json" author true | jq -r '"\(.kind) \(.key)"')"
check "conflict_enabled false: no conflict job" "nothing to address" "$(CONFLICT=false cls "$W/pr-dirty.json" "$W/empty.json" "$W/empty.json" "$W/empty.json" author true | jq -r .skip)"
echo '[{"id":9,"user":{"login":"pal"},"author_association":"MEMBER","body":"please add x"}]' >"$W/c.json"
check "conflict plus feedback: the fix runs first, the conflict is carried along" "fix true" "$(cls "$W/pr-dirty.json" "$W/empty.json" "$W/c.json" "$W/empty.json" author true | jq -r '"\(.kind) \(.conflict)"')"
jq -n '{check_runs: [{status: "completed", conclusion: "failure"}, {status: "completed", conclusion: "success"}]}' >"$W/ck-red.json"
jq -n '{check_runs: [{status: "completed", conclusion: "failure"}, {status: "in_progress", conclusion: null}]}' >"$W/ck-running.json"
check "own PR with failed CI and nothing else: a CI fix keyed on the head" "cifix cifix|acme/app|18|hhh888" "$(CHECKS=$W/ck-red.json cls "$FIX/pr-18.json" "$W/empty.json" "$W/empty.json" "$W/empty.json" author true | jq -r '"\(.kind) \(.key)"')"
check "CI still running: wait, nothing to do yet" "nothing to address" "$(CHECKS=$W/ck-running.json cls "$FIX/pr-18.json" "$W/empty.json" "$W/empty.json" "$W/empty.json" author true | jq -r .skip)"
check "ci_fix_enabled false: no CI fix" "nothing to address" "$(CI_ON=false CHECKS=$W/ck-red.json cls "$FIX/pr-18.json" "$W/empty.json" "$W/empty.json" "$W/empty.json" author true | jq -r .skip)"
echo '[{"id":9,"user":{"login":"pal"},"author_association":"MEMBER","body":"please add x"}]' >"$W/c.json"
check "feedback, conflict and red CI: steps in that order" "fix conflict cifix" "$(CHECKS=$W/ck-red.json cls "$W/pr-dirty.json" "$W/empty.json" "$W/c.json" "$W/empty.json" author true | jq -r '[.steps[].kind] | join(" ")')"
echo '[{"id":9,"user":{"login":"rando"},"author_association":"NONE","body":"x"}]' >"$W/c.json"
check "trusted_commenters can vouch for an outsider" fix "$(TRUSTED='["rando"]' cls "$FIX/pr-18.json" "$W/empty.json" "$W/c.json" "$W/empty.json" author true | jq -r .kind)"
jq '.requested_reviewers = []' "$FIX/pr-11.json" >"$W/pr-stale.json"
check "S2: stale review_requested notification (I am not requested any more): skipped" "not a current requested reviewer (stale notification)" \
  "$(cls "$W/pr-stale.json" "$W/empty.json" "$W/empty.json" "$W/empty.json" review_requested false | jq -r .skip)"
check "S2: same PR found by the review-requested search: reviewed" review "$(cls "$W/pr-stale.json" "$W/empty.json" "$W/empty.json" "$W/empty.json" review_requested true | jq -r .kind)"
check "S2: notification while I am still a requested reviewer: reviewed" review "$(cls "$FIX/pr-11.json" "$W/empty.json" "$W/empty.json" "$W/empty.json" review_requested false | jq -r .kind)"

echo "== safety: APPROVE is only auto-posted for org members"
reset; ASSOC=NONE ev review false; FAKE_CLAUDE=review job
check "outsider PR + APPROVE: draft only, nothing posted, user told" "1 0" "$(grep -c 'wrote an APPROVE draft but did not post it: the PR author is NONE' "$S/notified") $(cat "$S/writes.log" 2>/dev/null | grep -c 'POST .*reviews')"
check "and it is marked handled so it is not redone" 1 "$(grep -cxF "live|review|acme/app|11|$SHA" "$S/handled.tsv")"
reset; ASSOC=NONE ev review false; FAKE_CLAUDE=review-rc job
check "outsider PR + REQUEST_CHANGES still posts" 1 "$(cat "$S/writes.log" | grep -c 'event=REQUEST_CHANGES')"
reset; jq '. + {auto_approve_outsiders: true}' "$W/cfg.bak" >"$PR_AUTOPILOT_CONFIG"; ASSOC=NONE ev review false; FAKE_CLAUDE=review job
check "auto_approve_outsiders: true posts the APPROVE" 1 "$(cat "$S/writes.log" | grep -c 'event=APPROVE')"
cp "$W/cfg.bak" "$PR_AUTOPILOT_CONFIG"

echo "== safety: fail closed on dry_run"
reset; ev review false; jq 'del(.dry_run)' "$W/ev.json" >"$W/ev2.json"; mv "$W/ev2.json" "$W/ev.json"; FAKE_CLAUDE=review job
check "event without dry_run is a dry run" "1 0" "$(grep -c 'DRY RUN' "$S/notified") $(cat "$S/writes.log" 2>/dev/null | grep -c POST)"
reset; ev review false; jq '.dry_run = "false"' "$W/ev.json" >"$W/ev2.json"; mv "$W/ev2.json" "$W/ev.json"; FAKE_CLAUDE=review job
check "dry_run as the string \"false\" is still a dry run" 1 "$(grep -c 'DRY RUN' "$S/notified")"
reset; ev review false; jq '.dry_run = true' "$PR_AUTOPILOT_CONFIG" >"$W/c2" && mv "$W/c2" "$PR_AUTOPILOT_CONFIG"; FAKE_CLAUDE=review job
check "config switched back to dry mid-flight: nothing written" 0 "$(cat "$S/writes.log" 2>/dev/null | grep -c POST)"
cp "$W/cfg.bak" "$PR_AUTOPILOT_CONFIG"
printf '{"repos": {"acme/app": "/x"}, "dry_run": "false"}' >"$W/c3.json"
check "poller: dry_run that is not exactly false means dry" dry "$(PR_AUTOPILOT_CONFIG=$W/c3.json PR_AUTOPILOT_STATE=$W/st3 bash -c 'mkdir -p $PR_AUTOPILOT_STATE; . '"$T"'/../scripts/lib.sh; jq -r "if .dry_run == false then \"live\" else \"dry\" end" "$CONFIG"')"
printf '{ broken' >"$W/c4.json"
PR_AUTOPILOT_CONFIG=$W/c4.json PR_AUTOPILOT_STATE=$W/st4 PR_AUTOPILOT_JOB="$T/fake-job" bash "$T/../scripts/poll.sh" >/dev/null 2>&1
check "poller: corrupt config does nothing and exits non-zero" "1 no" "$? $([ -e "$W/st4/running" ] && ls "$W/st4/running" | grep -q . && echo yes || echo no)"

echo "== safety: process groups, mentions, slack, search chunks, origin, quiet skips"
reset; ev review false; rm -f "$S/hang.pid"
FAKE_CLAUDE=hang bash "$T/../scripts/job.sh" "$W/ev.json" & jp=$!
for i in $(seq 1 50); do [ -s "$S/hang.pid" ] && break; sleep 0.1; done
hp=$(cat "$S/hang.pid"); kill -TERM "$jp"; wait "$jp" 2>/dev/null; sleep 0.3
check "pause/TERM kills claude's whole process group, including its children" "gone" "$(kill -0 "$hp" 2>/dev/null && echo alive || echo gone)"
if [ "$(uname)" = Darwin ]; then
  jq -n '{repos: {"acme/app": "/x"}, notify_style: "notification"}' >"$W/c6.json"
  rep() { rm -f "$S/notified"; (PR_AUTOPILOT_CONFIG=$W/c6.json; . "$T/../scripts/lib.sh"; report "https://github.com/acme/app/pull/5
PR #5: done."); }
  rep; check "notify_style notification: a banner whose click opens the PR" 1 "$(grep -c '^TN -title pr-autopilot -message PR #5: done. -open https://github.com/acme/app/pull/5$' "$S/notified")"
  FAKE_TN_EXIT=3 rep; check "terminal-notifier not allowed yet: a plain notification with the link still shows" "1 1" "$(grep -c 'display notification.* -- https://github.com/acme/app/pull/5$' "$S/notified") $(grep -cx 'PR #5: done.' "$S/notified")"
fi
echo "-- chat inbox: results reach the user's Claude Code chats once"
IB="$T/../scripts/inbox.sh"; rm -f "$S/inbox.jsonl" "$S/inbox.read"
(. "$T/../scripts/lib.sh"; report "https://github.com/acme/app/pull/7
PR #7 (T): bob requested changes on yours. I fixed x, pushed abc1234.")
hk=$(bash "$IB" hook)
check "hook: the unread result becomes context for the reply, text and link" 1 "$(jq -r .hookSpecificOutput.additionalContext <<<"$hk" | grep -c '^- PR #7 (T): bob requested changes on yours. I fixed x, pushed abc1234. (https://github.com/acme/app/pull/7)$')"
check "hook: it is a UserPromptSubmit hook output" UserPromptSubmit "$(jq -r .hookSpecificOutput.hookEventName <<<"$hk")"
check "hook: already shown, so the next message gets nothing" "" "$(bash "$IB" hook)"
(. "$T/../scripts/lib.sh"; report "pr-autopilot: GitHub search failed")
check "watch tick: a new result prints once, also when it has no PR link" "- pr-autopilot: GitHub search failed" "$(bash "$IB" once)"
check "and is then read for the hook too" "" "$(bash "$IB" hook)"
rm -f "$S/inbox.jsonl"; check "hook with no inbox at all: silent, exit 0" "0 " "$(bash "$IB" hook; echo "$? $(bash "$IB" hook)")"
check "plugin hooks.json wires UserPromptSubmit to inbox.sh hook" 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/inbox.sh" hook' "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$T/../hooks/hooks.json")"
check "slack text is escaped" "&lt;!channel&gt; a&amp;b" "$(printf '<!channel> a&b' | (. "$T/../scripts/lib.sh"; slack_escape))"
check "mentions are defanged" 'hi `@bob` and `@org/team`' "$(printf 'hi @bob and @org/team' | (. "$T/../scripts/lib.sh"; defang) | tr -d '\n')"
jq -n '{repos: ([range(0;30) | {key: "some-organisation/a-rather-long-repository-name-\(.)", value: "/x"}] | from_entries)}' >"$W/c5.json"
chunks=$(PR_AUTOPILOT_CONFIG=$W/c5.json bash -c '. '"$T"'/../scripts/lib.sh; repo_chunks 200')
check "search query is split into chunks under the length limit" "ok" "$(awk 'length($0) > 200 {bad=1} END {print bad ? "too long" : "ok"}' <<<"$chunks")"
check "and no repo is lost in the split" 30 "$(tr ' ' '\n' <<<"$chunks" | grep -c '^repo:')"
check "more than one chunk was needed" 1 "$([ "$(wc -l <<<"$chunks" | tr -d ' ')" -gt 1 ] && echo 1 || echo 0)"
git -C "$W/clone" remote set-url origin https://github.com/other/thing.git
reset; ev review false; FAKE_CLAUDE=review job
check "origin that does not match the configured repo: refused before fetch or push" 1 "$(grep -c "does not point at acme/app" "$S/notified")"
git -C "$W/clone" remote set-url origin https://github.com/acme/app.git
reset; ev review false deadbeef; for i in 1 2 3; do FAKE_CLAUDE=review job; done
check "a PR that keeps changing is reported on the 3rd quiet skip" 1 "$(grep -c 'Skipped 3 times because the PR keeps changing' "$S/notified")"
if [ "$(uname)" = Darwin ]; then
  rm -f "$S/notified"; jq -n '{repos: {"acme/app": "/x"}, notify_style: "notification"}' >"$W/c7.json"
  out=$(PR_AUTOPILOT_CONFIG=$W/c7.json bash "$T/../scripts/install-scheduler.sh" notify-test)
  check "setup with notify_style notification sends the test banner" "1 1" "$(grep -cx 'TN -title pr-autopilot -message test -open https://github.com' "$S/notified") $(grep -c 'Sent a test notification' <<<"$out")"
  rm -f "$S/notified"; out=$(FAKE_TN_EXIT=3 PR_AUTOPILOT_CONFIG=$W/c7.json bash "$T/../scripts/install-scheduler.sh" notify-test)
  check "blocked by macOS: tells the user where to allow it" 1 "$(grep -c 'System Settings > Notifications > terminal-notifier' <<<"$out")"
  jq -n '{repos: {"acme/app": "/x"}, notify_style: "window"}' >"$W/c8.json"
  rm -f "$S/notified"; PR_AUTOPILOT_CONFIG=$W/c8.json bash "$T/../scripts/install-scheduler.sh" notify-test >/dev/null
  check "window style: no test banner" 0 "$(cat "$S/notified" 2>/dev/null | grep -c '^TN')"
fi
check "plugin version is 0.2.0 and the installer reports it" "0.2.0 1" "$(jq -r .version "$T/../.claude-plugin/plugin.json") $(HOME=$W/nohome bash "$T/../scripts/install-scheduler.sh" version | grep -c '^source:    0.2.0')"
if ! command -v notify-send >/dev/null; then
  mkdir -p "$W/linux"; printf '#!/usr/bin/env bash\necho Linux\n' >"$W/linux/uname"; chmod +x "$W/linux/uname"
  (PATH="$W/linux:$PATH"; . "$T/../scripts/lib.sh"; report "no link here") >/dev/null 2>&1
  check "Linux without notify-send: logged, not silent" 1 "$(grep -c 'no notify-send; desktop notification skipped' "$S/polls.log")"
fi
check "uninstall and install both clear a leftover pause" 2 "$(grep -c 'rm -f "$STATE/paused"' "$T/../scripts/install-scheduler.sh")"
check "plist PATH is XML-escaped" 1 "$(PATH='/a&b:/usr/bin:/bin' bash "$T/../scripts/install-scheduler.sh" print-plist | grep -c '/a&amp;b')"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
