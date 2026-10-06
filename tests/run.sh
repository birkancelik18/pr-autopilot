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
chmod +x "$W/bin/"* "$T/fake-job"
export PATH="$W/bin:$PATH" FIX="$W/fix" PR_AUTOPILOT_STATE="$W/state" PR_AUTOPILOT_CONFIG="$W/config.json"
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
jq '. + [{"id":5003,"user":{"login":"bob"},"body":"also this"}]' "$FIX/comments-12.json" >"$W/x" && mv "$W/x" "$FIX/comments-12.json"
bump 11; bump 12
poll; check "new head and new comment start exactly two more" 6 "$(jobs_n)"
poll; check "and then no more" 6 "$(jobs_n)"
mkcfg true '{"ignore_authors": []}'; : >"$S/seen.tsv"; poll
check "unignored non-[bot] author counts, [bot] logins and own comments never do" 1 \
  "$(grep -cxF '["fix","acme/app",18,"hhh888",true,"fix|acme/app|18|r0-v0-c6001-i0"]' "$S/jobs.log")"
check "carol's later APPROVED overrides her CHANGES_REQUESTED (no r id)" 0 "$(grep -c 'acme/app|18|r1' "$S/jobs.log")"

echo "== poller: failures retry at most 3 times with backoff"
jq '.head.sha = "iii000"' "$FIX/pr-19.json" >"$W/x" && mv "$W/x" "$FIX/pr-19.json"; bump 19
age() { awk -F'\t' 'BEGIN{OFS="\t"} {$1 = 1; print}' "$S/failed.tsv" >"$W/f" && mv "$W/f" "$S/failed.tsv"; }
before=$(jobs_n)
FAKE_JOB_FAIL=1 poll; check "failing job ran once" $((before + 1)) "$(jobs_n)"
poll; check "recent failure: backing off" $((before + 1)) "$(jobs_n)"
age; FAKE_JOB_FAIL=1 poll; age; FAKE_JOB_FAIL=1 poll
check "retried after backoff, attempts 2 and 3" $((before + 3)) "$(jobs_n)"
age; poll; check "after 3 failures it gives up" $((before + 3)) "$(jobs_n)"
check "give-up is logged" 1 "$([ "$(plog 'gave up on')" -ge 1 ] && echo 1 || echo 0)"

echo "== poller: going live does not replay the backlog"
before=$(jobs_n)
mkcfg false; poll
check "switch to live: older unread notifications are skipped" "$before" "$(jobs_n)"
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
git -C "$W/clone" config user.name t; git -C "$W/clone" config user.email t@t
jq --arg s "$SHA" '.head.sha = $s | .head.ref = "feature-11"' "$FIX/pr-11.json" >"$W/x" && mv "$W/x" "$FIX/pr-11.json"
jq -n --arg c "$W/clone" '{repos: {"acme/app": $c}, dry_run: false}' >"$PR_AUTOPILOT_CONFIG"
ev() { # ev <kind> <dry_run> [head]
  local key="review|acme/app|11|$SHA" who=alice cr=false
  [ "$1" = fix ] && { key="fix|acme/app|11|r901-v0-c5001-i0"; who=bob; cr=true; }
  jq -n --arg k "$1" --argjson d "$2" --arg h "${3:-$SHA}" --arg key "$key" --arg who "$who" --argjson cr "$cr" \
    '{kind:$k, key:$key, repo:"acme/app", number:11, head:$h, branch:"feature-11", base:"main",
      title:"PR 11 title", url:"https://x/11", dry_run:$d, attempt:0, who:$who, cr:$cr, thread:"t1", reason:"x"}' >"$W/ev.json"
}
job() { bash "$T/../scripts/job.sh" "$W/ev.json"; }
reset() { rm -rf "$S/fake" "$S/writes.log" "$S/handled.tsv" "$S/failed.tsv" "$S/notified" "$S/claude."*; }
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
check "base .claude/rules is given as a data file" "rule one" "$(cat "$(cat "$S/claude.jobdir")/conventions/.claude__rules__r1.md.txt")"
check "job log records subagent calls, parallelism, turns, duration, cost" 1 "$(grep -c '^stats: agent_calls=3 max_agents_in_one_message=3 num_turns=5 duration_ms=1234 cost_usd=0.5$' "$S/logs/"*review.log)"
check "claude is asked for stream-json" 1 "$(grep -cxF stream-json "$S/claude.args")"
check "diff and reviews are pre-fetched" 1 "$([ -s "$(cat "$S/claude.jobdir")/diff.patch" ] && [ -s "$(cat "$S/claude.jobdir")/reviews.json" ] && echo 1 || echo 0)"
check "dry-run writes nothing to GitHub" 0 "$([ -e "$S/writes.log" ] && wc -l <"$S/writes.log" | tr -d ' ' || echo 0)"
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

echo "-- review: bad drafts and failures are loud, nothing is posted"
reset; ev review false; FAKE_CLAUDE=review-long job
check "over 150 words fails" 1 "$(grep -c 'FAILED (attempt 1 of 3): draft body is 200 words' "$S/notified")"
check "failure is recorded for retry" 1 "$(grep -c "live|review|acme/app|11|$SHA" "$S/failed.tsv")"
check "nothing written, notification left unread" 0 "$([ -e "$S/writes.log" ] && wc -l <"$S/writes.log" | tr -d ' ' || echo 0)"
FAKE_CLAUDE=review-badverdict job; check "bad VERDICT line fails" 1 "$(grep -c "must be 'VERDICT: APPROVE'" "$S/notified")"
FAKE_CLAUDE=none job; check "missing draft fails" 1 "$(grep -c 'wrote no draft.md' "$S/notified")"
check "third failure says giving up" 1 "$(grep -c 'attempt 3 of 3, giving up' "$S/notified")"
reset; FAKE_CLAUDE=crash job; check "claude crash is reported" 1 "$(grep -c 'FAILED (attempt 1 of 3): claude exited with status 1' "$S/notified")"
reset; ev review false; FAKE_AGENTS=2 FAKE_CLAUDE=review job
check "fewer than three review passes fails loudly, nothing posted, retry recorded" "1 1 0" "$(grep -c 'FAILED (attempt 1 of 3): review needs three parallel passes but only 2 subagent call(s) ran' "$S/notified") $(grep -c 'live|review' "$S/failed.tsv") $(cat "$S/writes.log" 2>/dev/null | grep -c POST)"
reset; ev review false deadbeef; FAKE_CLAUDE=review job
check "head moved before start: quiet skip, no failure, no post" "0 0" "$(cat "$S/notified" 2>/dev/null | wc -l | tr -d ' ') $([ -e "$S/failed.tsv" ] && echo 1 || echo 0)"
reset; touch "$S/paused"; ev review false; FAKE_CLAUDE=review job; rm "$S/paused"
check "pause aborts the job before claude runs, silently" "0 0" "$(cat "$S/notified" 2>/dev/null | wc -l | tr -d ' ') $([ -e "$S/claude.args" ] && echo 1 || echo 0)"

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
check "commit message from result.json" "Add null check" "$(git -C "$O" log -1 --format=%s "$new")"
check "no other ref was touched (no force, no new branches)" "refs/heads/feature-11 refs/heads/main refs/pull/11/head" \
  "$(git -C "$O" for-each-ref --format='%(refname)' | sort | tr '\n' ' ' | sed 's/ $//')"
check "agent config files were not deleted by the commit" 0 "$(git -C "$O" diff --name-status "$SHA" "$new" | grep -c '^D')"
check "reply posted on the thread with the real short sha" "POST repos/acme/app/pulls/11/comments/5001/replies body=Fixed in ${new:0:7}." "$(grep 'replies' "$S/writes.log")"
check "re-request only for actual reviewers (stranger dropped)" "POST repos/acme/app/pulls/11/requested_reviewers bob" "$(grep requested_reviewers "$S/writes.log")"
check "report states verified facts" 1 "$(grep -c "I fixed the missing null check, pushed ${new:0:7}, replied on 1 thread(s), re-requested review from @bob (verified on GitHub)" "$S/notified")"
echo "-- fix: malformed result writes nothing"
git -C "$O" update-ref refs/heads/feature-11 "$SHA"; reset; ev fix false
FAKE_HEAD_REPO=$O FAKE_CLAUDE=fix-badreply job
check "reply to a nonexistent comment id is rejected before any write" "1 0" "$(grep -c 'malformed' "$S/notified") $([ -e "$S/writes.log" ] && wc -l <"$S/writes.log" | tr -d ' ' || echo 0)"
check "and the branch is untouched" "$SHA" "$(git -C "$O" rev-parse refs/heads/feature-11)"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
