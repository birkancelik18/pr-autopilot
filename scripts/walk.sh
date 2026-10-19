#!/usr/bin/env bash
# Helpers for /pr-autopilot:walk. Usage:
#   walk.sh draft <owner/repo> <n>   the saved private draft (JSON), or exit 1 when there is none
#   walk.sh head  <owner/repo> <n>   the PR's current head sha and state: "<sha> <open|closed>"
#   walk.sh post  <owner/repo> <n> <sha> <APPROVE|REQUEST_CHANGES|COMMENT> <body-file>
# post is the user's explicit pick: it refuses (exit 3) unless the PR is open and still at <sha>, the
# head the user walked, and pins the review to that sha.
set -uo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/lib.sh"
cmd=${1:-} repo=${2:-} n=${3:-}
[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && $n =~ ^[0-9]+$ ]] || { echo "usage: walk.sh draft|head|post <owner/repo> <n> ..." >&2; exit 2; }
cur_head() { gh api "repos/$repo/pulls/$n" --jq '[.head.sha, .state] | join(" ")'; }
case $cmd in
  draft) cat "$STATE_DIR/walks/${repo//\//_}-$n.json" 2>/dev/null || exit 1 ;;
  head) cur_head ;;
  post)
    sha=${4:-} event=${5:-} body=${6:-}
    case $event in APPROVE|REQUEST_CHANGES|COMMENT) ;; *) echo "event must be APPROVE, REQUEST_CHANGES or COMMENT" >&2; exit 2 ;; esac
    [ -n "$sha" ] && { [ "$event" = APPROVE ] || [ -s "$body" ]; } || { echo "need the walked sha, and a body file unless approving" >&2; exit 2; }
    cur=$(cur_head) || { echo "cannot read the PR from GitHub" >&2; exit 1; }
    if [ "$cur" != "$sha open" ]; then
      echo "NOT POSTED: the PR is now '$cur', you walked $sha. Walk the new part, then post." >&2; exit 3
    fi
    args=(-f commit_id="$sha" -f event="$event")
    [ -s "$body" ] && { defang <"$body" >"$body.safe" && args+=(-F body=@"$body.safe"); }
    gh api -X POST "repos/$repo/pulls/$n/reviews" "${args[@]}" --jq '"posted \(.state) review \(.id) on \(.commit_id)"'
    rc=$?; rm -f "$body.safe"; exit $rc ;;
  *) echo "usage: walk.sh draft|head|post ..." >&2; exit 2 ;;
esac
