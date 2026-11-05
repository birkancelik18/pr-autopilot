# shellcheck shell=bash
# Shared helpers, sourced by poll.sh, job.sh and ctl.sh. Needs bash, gh, jq, git, claude.
STATE_DIR=${PR_AUTOPILOT_STATE:-$HOME/.local/state/pr-autopilot}
CONFIG=${PR_AUTOPILOT_CONFIG:-$HOME/.config/pr-autopilot/config.json}
# shellcheck disable=SC2034 # used by job.sh
PLUGIN_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
mkdir -p "$STATE_DIR"/{logs,running,events,worktrees,jobs}
touch "$STATE_DIR/polls.log"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$STATE_DIR/polls.log"; }
cfg() { jq -r "$1" "$CONFIG"; } # usage: cfg '.slack_webhook // ""'
# cfgd <key> <default-json>: like cfg but keeps an explicit false (jq's // would replace it).
cfgd() { jq -r --argjson d "$2" ".$1 as \$v | if \$v == null then \$d else \$v end" "$CONFIG"; }

# mode_of <config key>: off | notify | walk | act. Missing means act (today's behaviour). An unknown value
# means notify: fail closed to "tell me, do nothing" rather than acting on a typo.
mode_ok() { # mode_ok <config key> <value>: walk only makes sense for reviewing_mode
  case $2 in off|notify|act) return 0 ;; walk) [ "$1" = reviewing_mode ] ;; *) return 1 ;; esac
}
mode_list() { [ "$1" = reviewing_mode ] && echo "off|notify|walk|act" || echo "off|notify|act"; }
mode_of() {
  local v; v=$(cfgd "$1" '"act"')
  if mode_ok "$1" "$v"; then echo "$v"; else echo notify; fi
}
# mode_show <config key>: the raw value, marked when mode_of would not take it as written.
mode_show() {
  local v; v=$(cfgd "$1" '"act"')
  if mode_ok "$1" "$v"; then echo "$v"; else echo "$v (unknown, treated as notify)"; fi
}

# legacy_ci_keys: the removed local-CI config keys still present in the config, space-separated (empty when none).
legacy_ci_keys() {
  jq -r '[("ci_source", "ci_container", "ci_timeout_minutes") as $k | select(has($k)) | $k] | join(" ")' "$CONFIG" 2>/dev/null || true
}

# with_timeout <seconds> <command...>: runs an external command, stopped (TERM, then KILL) after <seconds>;
# exits 124 then, like coreutils timeout. Uses gtimeout/timeout when installed (macOS has neither by
# default), else perl. PR_AUTOPILOT_TIMEOUT_BIN="" forces the perl path (tests).
with_timeout() {
  local s=$1 tb; shift
  tb=${PR_AUTOPILOT_TIMEOUT_BIN-$(command -v gtimeout || command -v timeout)}
  [ -z "$tb" ] || { "$tb" -k 5 "$s" "$@"; return; }
  # Own process group, so a timeout or a TERM to us stops the command's children too (git spawns ssh/https helpers).
  perl -e 'my $t = shift; my $pid = fork; defined $pid or die "fork: $!\n";
    if (!$pid) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; die "exec $ARGV[0]: $!\n" }
    my $stop = sub { kill "TERM", -$pid; sleep 1; kill "KILL", -$pid; exit $_[0] };
    $SIG{TERM} = sub { $stop->(143) }; $SIG{INT} = sub { $stop->(130) }; $SIG{ALRM} = sub { $stop->(124) };
    alarm $t; waitpid $pid, 0; my $st = $?; alarm 0;
    exit($st & 127 ? 128 + ($st & 127) : $st >> 8)' "$s" "$@"
}
# Per-call limit for every gh and networked git call (config gh_timeout_seconds, default 60): an outage
# must fail fast, not hang a job until job_timeout_minutes.
GH_TIMEOUT=$(cfgd gh_timeout_seconds 60 2>/dev/null)
[[ $GH_TIMEOUT =~ ^[1-9][0-9]*$ ]] || GH_TIMEOUT=60
# git_net <git args...>: git fetch/push with the same limit; a timeout marks the run transient (job.sh).
git_net() {
  local rc
  with_timeout "$GH_TIMEOUT" git "$@"; rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "git timed out after ${GH_TIMEOUT}s (GitHub unreachable?)" >&2
    [ -z "${PR_AUTOPILOT_TRANSIENT_FILE:-}" ] || : >"$PR_AUTOPILOT_TRANSIENT_FILE"
  fi
  return "$rc"
}

# gh: every call in the scripts goes through this wrapper (it shadows the binary). A transient network or
# API error (the regex below) is retried after PR_AUTOPILOT_GH_RETRY seconds (default "2 5 10"); the
# last try's output and exit status pass through. Writes (-X POST/PATCH/PUT/DELETE, -f/-F fields, gh pr
# review/comment/create/edit) are retried only on 429 / secondary rate limit, which GitHub rejects before
# applying anything: after a 502 or a reset the write may have landed, and a blind resend would post twice
# as the user (job.sh reads back before re-sending). Each try is cut off after GH_TIMEOUT seconds (exit
# 124, not retried). When retries run out on a read, or a read times out, the file
# PR_AUTOPILOT_TRANSIENT_FILE is created (job.sh uses it to not burn an attempt).
GH_TRANSIENT_RE="can't assign requested address|connection reset|i/o timeout|TLS handshake timeout|HTTP (429|50[234])|secondary rate limit|error connecting to|connection refused|no such host|unexpected EOF|timeout awaiting"
GH_REJECTED_RE="HTTP 429|secondary rate limit"
gh() {
  local out err rc delay re=$GH_TRANSIENT_RE write=0 a prev=""
  for a in "$@"; do
    case $(printf '%s' "$prev$a" | tr a-z A-Z) in # upper-cased: "-X post" is a write too
      -XPOST | -XPATCH | -XPUT | -XDELETE | -F* | --FIELD* | --RAW-FIELD* | --METHOD*) write=1 ;;
    esac
    prev=$a
  done
  case ${1:-} in pr) case ${2:-} in review | comment | create | edit | merge | close) write=1 ;; esac ;; esac
  # A GraphQL query is a read even though its variables go in -f/-F fields; only a mutation writes.
  [ "${1:-} ${2:-}" = "api graphql" ] && ! grep -q mutation <<<"$*" && write=0
  [ "$write" = 0 ] || re=$GH_REJECTED_RE
  [ -z "${PR_AUTOPILOT_TRANSIENT_FILE:-}" ] || rm -f "$PR_AUTOPILOT_TRANSIENT_FILE" # scoped to the last call
  out=$(mktemp) err=$(mktemp)
  # The trailing "" is the last try: no sleep after it.
  for delay in ${PR_AUTOPILOT_GH_RETRY:-2 5 10} ""; do
    with_timeout "$GH_TIMEOUT" gh "$@" >"$out" 2>"$err"; rc=$?
    [ "$rc" -ne 0 ] || break
    if [ "$rc" -eq 124 ]; then # hung: an outage, retrying would only stack up minutes. A write may have landed.
      echo "gh timed out after ${GH_TIMEOUT}s (GitHub unreachable?)" >>"$err"
      [ "$write" = 1 ] || [ -z "${PR_AUTOPILOT_TRANSIENT_FILE:-}" ] || : >"$PR_AUTOPILOT_TRANSIENT_FILE"
      break
    fi
    grep -qiE "$re" "$out" "$err" || break
    if [ -z "$delay" ]; then
      [ "$write" = 1 ] || [ -z "${PR_AUTOPILOT_TRANSIENT_FILE:-}" ] || : >"$PR_AUTOPILOT_TRANSIENT_FILE"
      break
    fi
    sleep "$delay"
  done
  cat "$out"; cat "$err" >&2; rm -f "$out" "$err"
  return "$rc"
}
is_paused() { [ -f "$STATE_DIR/paused" ]; }

# claude_limited holds the epoch the pause ends (job.sh writes it); an empty file (older version) means 30 minutes from its mtime.
limit_active() {
  local f="$STATE_DIR/claude_limited" until
  [ -e "$f" ] || return 1
  until=$(cat "$f" 2>/dev/null)
  case $until in
    '' | *[!0-9]*) [ -n "$(find "$f" -mmin -30 2>/dev/null)" ] ;;
    *) [ "$(date +%s)" -lt "$until" ] ;;
  esac
}
# epoch_date <epoch> [+format]: date of an epoch on macOS (date -r) and Linux (date -d @).
epoch_date() { date -r "$1" "${@:2}" 2>/dev/null || date -d "@$1" "${@:2}"; }
# limit_until <claude's message>: epoch when the limit resets ("resets 3:20pm (Europe/Istanbul)"), else now + 30 min.
# ponytail: only today/tomorrow clock times; "resets Oct 21, 3am" style falls back to 30 minutes.
limit_until() {
  local now t tz e
  now=$(date +%s)
  t=$(grep -oiE 'resets [0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m' <<<"$1" | head -1 | sed -E 's/^[Rr]esets //' | tr -d ' ' | tr 'A-Z' 'a-z')
  tz=$(grep -oE 'resets [^(]*\(([A-Za-z_]+/[A-Za-z_+-]+|UTC)\)' <<<"$1" | head -1 | sed -E 's/.*\(([^)]*)\)/\1/')
  if [ -n "$t" ]; then
    case $t in *:*) ;; *) t=${t%[ap]m}:00${t: -2} ;; esac
    e=$(${tz:+env TZ="$tz"} date -j -f '%I:%M%p %S' "$t 00" +%s 2>/dev/null || ${tz:+env TZ="$tz"} date -d "$t" +%s 2>/dev/null)
    case $e in '' | *[!0-9]*) ;; *)
      [ "$e" -gt "$now" ] || e=$((e + 86400))
      if [ "$e" -le $((now + 86400)) ]; then echo $((e + 60)); return; fi ;;
    esac
  fi
  echo $((now + 1800))
}
# Bot logins whose review threads are feedback (config review_bots); any other bot is not.
review_bots() { jq -c '(.review_bots | arrays) // ["coderabbitai[bot]"]' "$CONFIG"; }

# review_threads <owner/name> <pr>: the PR's review threads (first 100, last 20 comments each) as
# [{id, resolved, starter: {id, login, assoc} or null, comments: [{id, login, assoc}]}]. Only GraphQL knows
# whether a thread is resolved. starter is fetched on its own: past 20 comments, comments[0] is not it.
# A bot's login gets the "[bot]" suffix the REST API shows (coderabbitai -> coderabbitai[bot]).
review_threads() {
  gh api graphql -f owner="${1%%/*}" -f name="${1#*/}" -F number="$2" -f query='query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100) { nodes {
      id isResolved starter: comments(first: 1) { nodes { databaseId authorAssociation author { login __typename } } }
      comments(last: 20) { nodes { databaseId authorAssociation author { login __typename } } } } } } } }' |
    jq -e 'def c: {id: .databaseId, assoc: (.authorAssociation // "NONE"),
        login: ((.author.login // "ghost") + (if .author.__typename == "Bot" then "[bot]" else "" end))};
      [.data.repository.pullRequest.reviewThreads.nodes[] | {id, resolved: .isResolved,
        starter: ((.starter.nodes // [])[0] | if . then c else null end), comments: [.comments.nodes[] | c]}]'
}


# report <message>: macOS notification (notify-send on Linux) plus Slack if configured.
report() {
  local msg=$1 hook
  log "REPORT $msg"
  # A message whose first line is a PR link is shown per config notify_style:
  # - "window" (default): a small window with an "Open PR" button; needs nothing. Started in the
  #   background (the job must not wait on a human); it closes itself after 60s.
  # - "notification": a banner whose click opens the PR. Needs terminal-notifier, installed and
  #   allowed in System Settings; until then it falls back to a plain notification.
  local url body style
  url=$(head -1 <<<"$msg" | grep -oE '^https://[^ ]+$')
  body=$(tail -n +2 <<<"$msg")
  style=$(cfg '.notify_style // "window"' 2>/dev/null || echo window)
  # Unread list for the user's Claude Code chats (scripts/inbox.sh: hook and /pr-autopilot:watch).
  jq -nc --arg at "$(date -u +%FT%TZ)" --arg url "$url" --arg text "${body:-$msg}" \
    '{at: $at, url: $url, text: $text}' >>"$STATE_DIR/inbox.jsonl" 2>/dev/null ||
    log "could not write inbox.jsonl"
  if [ "$(uname)" = Darwin ] && [ -n "$url" ] && [ "$style" = notification ] &&
    command -v terminal-notifier >/dev/null &&
    terminal-notifier -title pr-autopilot -message "$body" -open "$url" >/dev/null 2>&1; then
    :
  elif [ "$(uname)" = Darwin ] && [ -n "$url" ] && [ "$style" != notification ]; then
    local dialog=(osascript -e 'on run argv'
      -e 'set r to display dialog (item 1 of argv) with title "pr-autopilot" buttons {"Close", "Open PR"} default button "Open PR" giving up after 60'
      -e 'if button returned of r is "Open PR" then open location (item 2 of argv)'
      -e 'end run' -- "$body" "$url")
    if [ -n "${PR_AUTOPILOT_SYNC_REPORT:-}" ]; then "${dialog[@]}" >/dev/null 2>&1 || log "dialog failed"
    else nohup "${dialog[@]}" >/dev/null 2>&1 </dev/null & fi
  elif [ "$(uname)" = Darwin ]; then
    osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "pr-autopilot"' \
      -e 'end run' -- "$msg" >/dev/null 2>&1 || log "osascript failed"
  elif command -v notify-send >/dev/null; then
    notify-send pr-autopilot "$msg" || log "notify-send failed"
  else
    log "no notify-send; desktop notification skipped"
  fi
  hook=$(cfg '.slack_webhook // ""' 2>/dev/null || true)
  if [ -n "$hook" ]; then
    curl -sS -m 20 -X POST -H 'Content-type: application/json' \
      -d "$(jq -nc --arg text "$(printf '%s' "$msg" | slack_escape)" '{text:$text}')" "$hook" >/dev/null 2>>"$STATE_DIR/polls.log" ||
      log "slack post failed"
  fi
}

# report_throttled <message> [stamp file name]: for poller-level failures that repeat every minute (max 1 per
# hour per stamp; the default stamp is shared by all errors, a config error passes its own so it is never swallowed).
report_throttled() {
  local f=$STATE_DIR/${2:-last_error_report}
  if [ ! -f "$f" ] || [ -n "$(find "$f" -mmin +60 2>/dev/null)" ]; then
    touch "$f"
    report "$1"
  else
    log "ERROR (report throttled) $1"
  fi
}

# repo_chunks <max-len>: one line per group of "repo:a repo:b" qualifiers short enough for GitHub's
# 256-char search query limit.
repo_chunks() {
  jq -r --argjson max "$1" '.repos | keys | map("repo:" + .)
    | reduce .[] as $r ([""]; if (.[-1] | length) + ($r | length) + 1 > $max then . + [$r]
      else (.[-1] |= (if . == "" then $r else . + " " + $r end)) end) | .[]' "$CONFIG"
}

# slack_escape: Slack treats <, > and & specially (<!channel> pings everyone).
slack_escape() { jq -Rrs 'gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")'; }

# defang: model-written text must not ping people; wrap @mentions in backticks.
defang() { jq -Rrs 'gsub("@(?<n>[A-Za-z0-9_][A-Za-z0-9_/-]*)"; "`@\(.n)`")'; }

# voice_check [approve]: model-written text to be posted on stdin; prints the machine tells it finds,
# "; "-joined (nothing when it reads like a person). The "Never" list in voice.md, which the model is
# given: keep both in step. Fenced code (suggestion blocks) is skipped.
voice_check() {
  LC_ALL=C awk -v approve="${1:-}" '
    /^[ \t]*(```|~~~)/ { code = !code; next }
    code { next }
    { words += NF; l = tolower($0) }
    /^ ? ? ?#+([ \t]|$)/ { p["a markdown heading"] = 1 }
    /^[ \t]*\|.*\|/ { p["a markdown table"] = 1 }
    l ~ /^[ \t]*([-*][ \t]+)?(\*\*)?(verdict|evidence|summary|findings|severity|recommendation|conclusion)(\*\*)?[ \t]*(\*\*)?:/ { p["a label line like Verdict:"] = 1 }
    /^[ \t]*([-*][ \t]+)?\*\*[^*]+\*\*/ { p["a line starting with a bold label"] = 1 }
    l ~ /\[(blocker|nit|major|minor|critical|high|medium|low|p[0-3])\]/ { p["a severity tag like [blocker]"] = 1 }
    index($0, "\342\200\224") { p["an em dash"] = 1 }
    l ~ /hope this helps|let me know if|as an ai|generated (by|with) / { p["a bot phrase"] = 1 }
    l ~ /(^|[^a-z])nits?([^a-z]|$)|not blocking|non-blocking|optional/ { nit = 1 }
    END {
      if (approve != "" && words > 60 && !nit) p["an APPROVE of " words " words with nothing marked as a nit (max 60)"] = 1
      for (k in p) print k
    }' | sort | paste -sd ';' - | sed 's/;/; /g'
}

# gc: drop leftovers of dead jobs (worktrees, refs) and rotate logs. Called by poll.sh.
# Directory and ref names end in the owning job's pid.
gc() {
  local d pid clone ref
  for d in "$STATE_DIR"/worktrees/*; do
    [ -d "$d" ] || continue
    pid=${d##*-}
    kill -0 "$pid" 2>/dev/null || rm -rf "$d"
  done
  if [ -f "$CONFIG" ]; then
    while IFS= read -r clone; do
      [ -d "$clone" ] || continue
      git -C "$clone" worktree prune 2>/dev/null
      git -C "$clone" for-each-ref --format='%(refname)' refs/pr-autopilot 2>/dev/null |
        while read -r ref; do
          pid=${ref##*-}
          kill -0 "$pid" 2>/dev/null || git -C "$clone" update-ref -d "$ref" 2>/dev/null
        done
    done < <(jq -r '.repos[]' "$CONFIG")
  fi
  find "$STATE_DIR/logs" "$STATE_DIR/jobs" "$STATE_DIR/events" -mindepth 1 -maxdepth 1 -mtime +14 \
    -exec rm -rf {} + 2>/dev/null
  # Empty the chat inbox once everything in it was shown and it got long.
  if [ -f "$STATE_DIR/inbox.jsonl" ] && [ "$(wc -l <"$STATE_DIR/inbox.jsonl")" -gt 500 ] &&
    [ "$(cat "$STATE_DIR/inbox.read" 2>/dev/null || echo 0)" -ge "$(wc -l <"$STATE_DIR/inbox.jsonl")" ]; then
    : >"$STATE_DIR/inbox.jsonl"; echo 0 >"$STATE_DIR/inbox.read"
  fi
  if [ "$(wc -c <"$STATE_DIR/polls.log" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    tail -n 2000 "$STATE_DIR/polls.log" >"$STATE_DIR/polls.log.tmp" &&
      mv "$STATE_DIR/polls.log.tmp" "$STATE_DIR/polls.log"
  fi
  return 0
}
