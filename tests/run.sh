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
git -C "$W/clone" remote set-url origin https://github.com/acme/app.git
git -C "$W/clone" config url."$O".insteadOf https://github.com/acme/app.git
git -C "$W/clone" config user.name t; git -C "$W/clone" config user.email t@t
jq --arg s "$SHA" '.head.sha = $s | .head.ref = "feature-11"' "$FIX/pr-11.json" >"$W/x" && mv "$W/x" "$FIX/pr-11.json"
jq -n --arg c "$W/clone" '{repos: {"acme/app": $c}, dry_run: false}' >"$PR_AUTOPILOT_CONFIG"; cp "$PR_AUTOPILOT_CONFIG" "$W/cfg0.json"
ev() { # ev <kind> <dry_run> [head]
  local key="review|acme/app|11|$SHA" who=alice cr=false
  [ "$1" = fix ] && { key="fix|acme/app|11|r901-v0-c5001-i0"; who=bob; cr=true; }
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
    --argjson fix_enabled true --slurpfile pr "$1" --slurpfile reviews "$2" --slurpfile comments "$3" --slurpfile issue "$4"
}
echo '[]' >"$W/empty.json"
for assoc in NONE CONTRIBUTOR FIRST_TIME_CONTRIBUTOR; do
  echo "[{\"id\":9,\"user\":{\"login\":\"rando\"},\"author_association\":\"$assoc\",\"body\":\"please add x\"}]" >"$W/c.json"
  check "feedback from a $assoc author is ignored (and counted)" "nothing to address 1" "$(cls "$FIX/pr-18.json" "$W/empty.json" "$W/c.json" "$W/empty.json" author true | jq -r '"\(.skip) \(.untrusted)"')"
done
for assoc in OWNER MEMBER COLLABORATOR; do
  echo "[{\"id\":9,\"user\":{\"login\":\"pal\"},\"author_association\":\"$assoc\",\"body\":\"please add x\"}]" >"$W/c.json"
  check "feedback from a $assoc starts a fix" fix "$(cls "$FIX/pr-18.json" "$W/empty.json" "$W/c.json" "$W/empty.json" author true | jq -r .kind)"
done
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
check "uninstall and install both clear a leftover pause" 2 "$(grep -c 'rm -f "$STATE/paused"' "$T/../scripts/install-scheduler.sh")"
check "plist PATH is XML-escaped" 1 "$(PATH='/a&b:/usr/bin:/bin' bash "$T/../scripts/install-scheduler.sh" print-plist | grep -c '/a&amp;b')"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
