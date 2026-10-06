# Decide what one PR means for us. No network: everything arrives as arguments.
# Args: --arg me --arg reason --arg repo
#       --argjson ignore (extra bot logins) --argjson trusted (extra trusted commenters)
#       --argjson via_search (true when the review request came from the search source)
#       --argjson allow_forks/review_enabled/fix_enabled
#       --slurpfile pr/reviews/comments/issue (each file holds one JSON value).
# Output: {skip: why} or {kind: "review"|"fix", key, ...} plus PR facts for the job.
def human: select(.user.login != $me and (.user.login | endswith("[bot]") | not)
    and (.user.login | IN($ignore[]) | not));
# Feedback only counts from people with a stake in the repo: its owner, org members, collaborators,
# or anyone listed in trusted_commenters. Everyone else's text is never turned into a fix job.
def trusted: ((.author_association // "NONE") | IN("OWNER", "MEMBER", "COLLABORATOR"))
    or (.user.login | IN($trusted[]));
def maxid: if length == 0 then null else max_by(.id) end;
($pr[0]) as $p | ($reviews[0]) as $rv | ($comments[0]) as $cm | ($issue[0]) as $ic
| (($p.head.repo.full_name // "") != $p.base.repo.full_name) as $fork
| ([($rv + $cm + $ic)[] | human | select(trusted | not)] | length) as $untrusted
| (
    if $p.state != "open" or ($p.merged // false) then {skip: "closed or merged"}
    elif $p.draft then {skip: "draft"}
    elif $p.user.login == $me then
      if ($fix_enabled | not) then {skip: "fix disabled"}
      elif $fork then {skip: "own PR from a fork, cannot push"}
      else
        # Each reviewer counts by their LATEST submitted review.
        ([$rv[] | human | select(trusted) | select(.state != "PENDING")] | group_by(.user.login) | map(max_by(.id))) as $latest
        | ([$latest[] | select(.state == "CHANGES_REQUESTED")] | maxid) as $cr
        | ([$rv[] | human | select(trusted) | select(.state == "COMMENTED" and ((.body // "") != ""))] | maxid) as $rc
        | ([$cm[] | human | select(trusted)] | maxid) as $c
        | ([$ic[] | human | select(trusted)] | maxid) as $i
        | if ([$cr, $rc, $c, $i] | all(. == null)) then {skip: "nothing to address"}
          else {
            kind: "fix",
            key: "fix|\($repo)|\($p.number)|r\($cr.id // 0)-v\($rc.id // 0)-c\($c.id // 0)-i\($i.id // 0)",
            cr: ($cr != null),
            who: ([$cr, $rc, $c, $i] | map(select(. != null) | .user.login) | unique | join(", "))
          } end
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
