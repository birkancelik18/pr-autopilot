# Decide what one PR means for us. No network: everything arrives as arguments.
# Args: --arg me --arg reason --arg repo
#       --argjson ignore (extra bot logins) --argjson trusted (extra trusted commenters)
#       --argjson via_search (true when the review request came from the search source)
#       --argjson allow_forks/review_enabled/fix_enabled/conflict_enabled/ci_enabled
#       --argjson ci_local (true when config ci_source is "local": CI is ci-local's record, never check runs)
#       --slurpfile pr/reviews/comments/issue/checks/cirec (each file holds one JSON value; checks is the
#       head commit's check-runs response, {"check_runs": []} when not fetched; cirec is the head's
#       ci-local record, null when there is none or ci_source is not local).
# Output: {skip: why} or {kind: "review"|"fix", key, ...} plus PR facts for the job.
def human: select(.user.login != $me and (.user.login | endswith("[bot]") | not)
    and (.user.login | IN($ignore[]) | not));
# Feedback only counts from people with a stake in the repo: its owner, org members, collaborators,
# or anyone listed in trusted_commenters. Everyone else's text is never turned into a fix job.
def trusted: ((.author_association // "NONE") | IN("OWNER", "MEMBER", "COLLABORATOR"))
    or (.user.login | IN($trusted[]));
def maxid: if length == 0 then null else max_by(.id) end;
($pr[0]) as $p | ($reviews[0]) as $rv | ($comments[0]) as $cm | ($issue[0]) as $ic | $checks as $ck | ($cirec[0]) as $rec
| "cilocal|\($repo)|\($p.number)|\($p.head.sha)" as $lkey
| (($p.head.repo.full_name // "") != $p.base.repo.full_name) as $fork
| ([($rv + $cm + $ic)[] | human | select(trusted | not)] | length) as $untrusted
| (
    if $p.state != "open" or ($p.merged // false) then {skip: "closed or merged"}
    elif $p.draft then {skip: "draft"}
    elif $p.user.login == $me then
      # Own PR: the steps that apply, in order: answer feedback, then resolve a merge conflict with
      # the base, then fix failing CI. The poller runs the first step not handled yet (poll.sh).
      if $fork then {skip: "own PR from a fork, cannot push"}
      else
        # Each reviewer counts by their LATEST submitted review.
        ([$rv[] | human | select(trusted) | select(.state != "PENDING")] | group_by(.user.login) | map(max_by(.id))) as $latest
        | ([$latest[] | select(.state == "CHANGES_REQUESTED")] | maxid) as $cr
        | ([$rv[] | human | select(trusted) | select(.state == "COMMENTED" and ((.body // "") != ""))] | maxid) as $rc
        | ([$cm[] | human | select(trusted)] | maxid) as $c
        | ([$ic[] | human | select(trusted)] | maxid) as $i
        | (if $fix_enabled and ([$cr, $rc, $c, $i] | any(. != null)) then [{
            kind: "fix",
            key: "fix|\($repo)|\($p.number)|r\($cr.id // 0)-v\($rc.id // 0)-c\($c.id // 0)-i\($i.id // 0)",
            cr: ($cr != null),
            who: ([$cr, $rc, $c, $i] | map(select(. != null) | .user.login) | unique | join(", "))
          }] else [] end) as $fixes
        # Merge conflict: GitHub says "dirty"; keyed on both shas, so a new conflict is a new job.
        | ($conflict_enabled and ($p.mergeable_state // "") == "dirty") as $dirty
        | "conflict|\($repo)|\($p.number)|\($p.head.sha)|\($p.base.sha // "")" as $ckey
        # Failing CI: every check run on the head commit finished and one failed or timed out. Local CI:
        # the head has no ci-local record yet (run it), or its record is fail or incomplete.
        | (if $ci_local then $ci_enabled and (($rec.result // "") | IN("fail", "incomplete"))
          else ($ck[0].check_runs // []) as $runs | $ci_enabled and ($runs | length) > 0
            and all($runs[]; .status == "completed")
            and any($runs[]; (.conclusion // "") | IN("failure", "timed_out")) end) as $red
        | ($fixes
            + (if $dirty then [{kind: "conflict", key: $ckey, who: "the base branch"}] else [] end)
            + (if $ci_local and $rec == null then [{kind: "cilocal", key: $lkey, who: "local CI"}] else [] end)
            + (if $red then [{kind: "cifix", key: "cifix|\($repo)|\($p.number)|\($p.head.sha)", who: "CI"}] else [] end)
          ) as $steps
        | if ($steps | length) == 0 then {skip: "nothing to address"}
          else $steps[0] + {steps: $steps, conflict: $dirty, conflict_key: $ckey} end
      end
    elif $reason == "review_requested" then
      if ($review_enabled | not) then {skip: "review disabled"}
      elif $fork and ($allow_forks | not) then {skip: "fork PR, allow_forks is off"}
      # A sticky notification alone must not start a review: we must still be a requested reviewer.
      elif ($via_search | not) and ((($p.requested_reviewers // []) | map(.login) | index($me)) == null) then
        {skip: "not a current requested reviewer (stale notification)"}
      elif ([$rv[] | select(.user.login == $me and .commit_id == $p.head.sha
          and (.state | IN("APPROVED", "CHANGES_REQUESTED", "COMMENTED")))] | length) > 0 then
        {skip: "already reviewed this head"}
      # Local CI: ci-local runs on the head first; the review's verdict depends on its record (job.sh).
      elif $ci_local and $rec == null then {kind: "cilocal", key: $lkey, who: $p.user.login}
      else {kind: "review", key: "review|\($repo)|\($p.number)|\($p.head.sha)", who: $p.user.login}
      end
    else {skip: "not actionable (reason: \($reason))"}
    end
  )
| . + {
    repo: $repo, number: $p.number, head: $p.head.sha, branch: $p.head.ref, base: $p.base.ref,
    title: $p.title, url: $p.html_url, author: $p.user.login,
    author_assoc: ($p.author_association // "NONE"), untrusted: $untrusted
  }
