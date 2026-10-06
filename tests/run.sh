#!/usr/bin/env bash
# No-network tests: poll.sh runs against a fake gh and a fake job. Usage: bash tests/run.sh
set -uo pipefail
T=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"
  else fail=$((fail + 1)); echo "FAIL $1: expected '$2' got '$3'"; fi
}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/state" && cp "$T/fake-gh" "$W/bin/gh" && chmod +x "$W/bin/gh" "$T/fake-job"
export PATH="$W/bin:$PATH" PR_AUTOPILOT_JOB="$T/fake-job" FIX="$W/fix"
export PR_AUTOPILOT_STATE="$W/state" PR_AUTOPILOT_CONFIG="$W/config.json"
cp -R "$T/fixtures" "$FIX"
S=$PR_AUTOPILOT_STATE
mkcfg() { jq -n --argjson dry "$1" '{repos: {"Acme/App": "/tmp/clone"}, dry_run: $dry, max_parallel: 5}' >"$PR_AUTOPILOT_CONFIG"; }
poll() { bash "$T/../scripts/poll.sh"; sleep 0.5; }
jobs_n() { wc -l <"$S/jobs.log" | tr -d ' '; }
: >"$S/jobs.log"

# --- classification (live mode): review for #11, fix for #12, everything else skipped
mkcfg false; poll
check "two jobs started" 2 "$(jobs_n)"
check "review job for #11 at head" 1 "$(grep -cxF '["review","acme/app",11,"aaa111",false,"review|acme/app|11|aaa111"]' "$S/jobs.log")"
check "fix job for #12 keyed on review+comment ids" 1 "$(grep -cxF '["fix","acme/app",12,"bbb222",false,"fix|acme/app|12|r901-c5001"]' "$S/jobs.log")"
check "threads marked read only for started jobs" "PATCH notifications/threads/t1 PATCH notifications/threads/t2" "$(sort "$S/writes.log" | tr '\n' ' ' | sed 's/ $//')"
for why in "skip acme/app#13: draft" "skip acme/app#14: closed or merged" "skip acme/app#16: fork PR, allow_forks is off" "skip acme/app#17: not actionable (reason: mention)"; do
  check "log: $why" 1 "$(grep -c -F "$why" "$S/polls.log")"
done
check "repo not in config is ignored" 0 "$(grep -c 'other/x' "$S/polls.log")"

# --- dedupe: same events again start nothing
poll; check "second poll starts nothing" 2 "$(jobs_n)"

# --- re-request after a push (new head sha) and a new reviewer comment run exactly once more
jq '.head.sha = "aaa222"' "$FIX/pr-11.json" >"$W/x" && mv "$W/x" "$FIX/pr-11.json"
jq '. + [{"id":5003,"user":{"login":"bob"},"body":"also this"}]' "$FIX/comments-12.json" >"$W/x" && mv "$W/x" "$FIX/comments-12.json"
poll; check "new head + new comment start two jobs" 4 "$(jobs_n)"
poll; check "and then no more" 4 "$(jobs_n)"

# --- dry-run: separate dedupe namespace, passes dry_run, never marks read
rm -f "$S/writes.log"; mkcfg true; poll
check "dry-run runs the events once in its own namespace" 6 "$(jobs_n)"
check "dry-run flag reaches the job" true "$(tail -1 "$S/jobs.log" | jq '.[4]')"
check "dry-run marks nothing read" no "$([ -e "$S/writes.log" ] && echo yes || echo no)"
poll; check "dry-run dedupes too" 6 "$(jobs_n)"

# --- head moved mid-job: retry entry is re-run even though its key was handled
printf 'acme/app\t11\treview_requested\t1\n' >"$S/retry.tsv"; poll
check "retry entry re-runs the review" 7 "$(jobs_n)"
check "retry file is consumed" 0 "$(wc -c <"$S/retry.tsv" | tr -d ' ')"

# --- pause and lock
touch "$S/paused"; : >"$S/handled.tsv"; poll
check "paused poll does nothing" 7 "$(jobs_n)"
rm "$S/paused"; mkdir "$S/poll.lock"; echo $$ >"$S/poll.lock/pid"; poll
check "live lock stops an overlapping poll" 7 "$(jobs_n)"
echo 999999 >"$S/poll.lock/pid"; poll
check "stale lock does not" 9 "$(jobs_n)"

# --- job.sh against a real throwaway git repo, a fake claude and a fake osascript
git init -q "$W/origin" && git -C "$W/origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$W/origin" update-ref refs/pull/11/head HEAD && git clone -q "$W/origin" "$W/clone"
SHA=$(git -C "$W/origin" rev-parse HEAD)
cat >"$W/bin/claude" <<'FC'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$@" >"$PR_AUTOPILOT_STATE/claude.args"
D='{"result":"done\nOUTCOME: I posted APPROVE: no blockers.","is_error":false}'
printf '%s\n' "${FAKE_RESULT:-$D}"
FC
printf '#!/usr/bin/env bash\necho "$@" >>"$PR_AUTOPILOT_STATE/notified"\n' >"$W/bin/osascript"
chmod +x "$W/bin/claude" "$W/bin/osascript"
jq -n --arg c "$W/clone" '{repos: {"acme/app": $c}, dry_run: false}' >"$PR_AUTOPILOT_CONFIG"
jq -n --arg h "$SHA" '{kind:"review", key:"k", repo:"acme/app", number:11, head:$h, branch:"feature-11",
  title:"PR 11 title", url:"https://x/11", dry_run:true, attempt:0, who:"alice", reason:"review_requested"}' >"$W/ev.json"
bash "$T/../scripts/job.sh" "$W/ev.json"
check "job reports the outcome" "1" "$(grep -c '\[DRY RUN\] PR #11 (PR 11 title): alice asked you to review it. I posted APPROVE: no blockers. https://x/11' "$S/notified")"
check "claude ran in the worktree, headless, narrow" "1" "$(grep -c -x -e 'dontAsk' "$S/claude.args")"
check "dry-run denies git push" "1" "$(grep -c 'Bash(git push \*)' "$S/claude.args")"
check "worktree removed after the job" "0" "$(git -C "$W/clone" worktree list | grep -c pr-autopilot)"
FAKE_RESULT='{"result":"OUTCOME: head-moved","is_error":false}' bash "$T/../scripts/job.sh" "$W/ev.json"
check "head-moved is re-queued, not reported" "$(printf 'acme/app\t11\treview_requested\t1')" "$(cat "$S/retry.tsv")"
FAKE_RESULT='{"result":"no outcome here","is_error":false}' bash "$T/../scripts/job.sh" "$W/ev.json"
check "missing OUTCOME is a loud failure" "1" "$(grep -c 'FAILED: skill finished without an OUTCOME line' "$S/notified")"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
