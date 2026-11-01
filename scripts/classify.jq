# Decide what one PR means for us. No network: everything arrives as arguments.
# Args: --arg me --arg reason --arg repo
#       --argjson ignore (extra bot logins) --argjson trusted (extra trusted commenters)
#       --argjson review_bots (bot logins whose review threads count, e.g. ["coderabbitai[bot]"])
#       --argjson via_search (true when the review request came from the search source)
#       --argjson review_max (optional: review_max_changed_lines, 0 = no limit)
#       --argjson review_authors (optional: logins whose open PRs are reviewed without a review request)
#       --argjson allow_forks/review_enabled/fix_enabled/conflict_enabled/ci_enabled
#       --slurpfile threads (review_threads in lib.sh: [{id, resolved, comments: [{id, login, assoc}]}],
#       [] when not fetched)
#       --slurpfile pr/reviews/comments/issue/checks (each file holds one JSON value; checks is the
#       head commit's check-runs response, {"check_runs": []} when not fetched).
# Output: {skip: why} or {kind: "review"|"fix", key, ...} plus PR facts for the job.
include "trust" {search: "./"};
def human: select(.user.login != $me and (.user.login | endswith("[bot]") | not)
    and (.user.login | IN($ignore[]) | not));
# Feedback only counts from people with a stake in the repo: its owner, org members, collaborators,
# or anyone listed in trusted_commenters. Everyone else's text is never turned into a fix job.
def trusted: ((.author_association // "NONE") | IN("OWNER", "MEMBER", "COLLABORATOR"))
    or (.user.login | IN($trusted[]));
def maxid: if length == 0 then null else max_by(.id) end;
($pr[0]) as $p | ($reviews[0]) as $rv | ($comments[0]) as $cm | ($issue[0]) as $ic | $checks as $ck
| (($p.head.repo.full_name // "") != $p.base.repo.full_name) as $fork
| ([($rv + $cm + $ic)[] | human | select(trusted | not)] | length) as $untrusted
# review_authors: decided on the PR's author as GitHub reports it now, never on how the item was found.
| (($p.user.login | ascii_downcase) | IN(($ARGS.named.review_authors // [])[] | ascii_downcase)) as $listed
| ($reason == "review_requested" and ($via_search
    or ((($p.requested_reviewers // []) | map(.login) | index($me)) != null))) as $requested
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
        # An approval can still carry open points ("lgtm with comments", a numbered list): a latest
        # APPROVED review whose body is more than a bare approval phrase.
        | ([$latest[] | select(.state == "APPROVED" and ((.body // "") | gsub("\\s+"; " ") | ascii_downcase
            | test("^ ?((lgtm|looks good( to me)?|approved?|ship ?it|nice( work)?|great( work)?|thanks?( you)?)[ .!]*|:shipit:|\\+1|👍|🚀)? ?$") | not))] | maxid) as $ap
        # Unresolved review threads that a trusted voice started (.starter, fetched on its own; me, a trusted person, or a known review
        # bot such as CodeRabbit: a bot can relay a stranger, so any other bot does not count) and whose
        # newest comment is from a trusted voice other than me (my own reply last: nothing new).
        # Keyed on that newest comment, so a new one runs again (capped per PR in poll.sh).
        | def tvoice: tvoice($me; $ignore; $review_bots; $trusted); # trust.jq: job.sh filters the model's input with it too
          ([($threads[0] // [])[] | select(.resolved | not) | select(.starter != null and (.starter | tvoice))
            | .comments | last | select(.login != $me and tvoice)]
          | if length == 0 then null else max_by(.id) | {id, user: {login}} end) as $t
        | (if $fix_enabled and ([$cr, $rc, $c, $i, $ap, $t] | any(. != null)) then [{
            kind: "fix",
            # -a/-t only when present: keys of PRs without them stay what they were (no replay).
            key: ("fix|\($repo)|\($p.number)|r\($cr.id // 0)-v\($rc.id // 0)-c\($c.id // 0)-i\($i.id // 0)"
              + (if $ap then "-a\($ap.id)" else "" end) + (if $t then "-t\($t.id)" else "" end)),
            cr: ($cr != null),
            who: ([$cr, $rc, $c, $i, $ap, $t] | map(select(. != null) | .user.login) | unique | join(", "))
          }] else [] end) as $fixes
        # Merge conflict: GitHub says "dirty"; keyed on both shas, so a new conflict is a new job.
        | ($conflict_enabled and ($p.mergeable_state // "") == "dirty") as $dirty
        | "conflict|\($repo)|\($p.number)|\($p.head.sha)|\($p.base.sha // "")" as $ckey
        # Failing CI: every check run on the head commit finished and one failed or timed out.
        | (($ck[0].check_runs // []) as $runs | $ci_enabled and ($runs | length) > 0
            and all($runs[]; .status == "completed")
            and any($runs[]; (.conclusion // "") | IN("failure", "timed_out"))) as $red
        | ($fixes
            + (if $dirty then [{kind: "conflict", key: $ckey, who: "the base branch"}] else [] end)
            + (if $red then [{kind: "cifix", key: "cifix|\($repo)|\($p.number)|\($p.head.sha)", who: "CI"}] else [] end)
          ) as $steps
        | if ($steps | length) == 0 then {skip: "nothing to address"}
          else $steps[0] + {steps: $steps, conflict: $dirty, conflict_key: $ckey} end
      end
    elif $reason == "review_requested" or $listed then
      if ($review_enabled | not) then {skip: "review disabled"}
      elif $fork and ($allow_forks | not) then {skip: "fork PR, allow_forks is off"}
      # A sticky notification alone must not start a review: we must still be a requested reviewer.
      elif ($requested or $listed) | not then
        {skip: "not a current requested reviewer (stale notification)"}
      elif ([$rv[] | select(.user.login == $me and .commit_id == $p.head.sha
          and (.state | IN("APPROVED", "CHANGES_REQUESTED", "COMMENTED")))] | length) > 0 then
        {skip: "already reviewed this head"}
      # Over review_max_changed_lines (additions + deletions, 0 or missing = no limit): poll.sh tells the owner once per head.
      # A limit is set but GitHub gave no size: fail closed (no review), poll.sh says so once per head.
      elif (($ARGS.named.review_max // 0) > 0) and ($p.additions == null or $p.deletions == null) then
        {skip: "review size unknown", nosize: true}
      elif (($ARGS.named.review_max // 0) > 0) and ($p.additions + $p.deletions) > $ARGS.named.review_max then
        {skip: "review too large", lines: ($p.additions + $p.deletions)}
      else {kind: "review", key: "review|\($repo)|\($p.number)|\($p.head.sha)", who: $p.user.login}
        + (if $requested then {} else {by_author: true} end)
      end
    else {skip: "not actionable (reason: \($reason))"}
    end
  )
| . + {
    repo: $repo, number: $p.number, head: $p.head.sha, branch: $p.head.ref, base: $p.base.ref,
    title: $p.title, url: $p.html_url, author: $p.user.login,
    author_assoc: ($p.author_association // "NONE"), untrusted: $untrusted
  }
