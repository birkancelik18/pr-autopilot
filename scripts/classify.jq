# Decide what one PR notification means. No network: everything arrives as arguments.
# Args: --arg me --arg reason --arg repo --argjson allow_forks/review_enabled/fix_enabled
#       --slurpfile pr/reviews/comments (each file holds one JSON value).
# Output: {skip: why} or {kind: "review"|"fix", key, ...} plus PR facts for the job.
($pr[0]) as $p | ($reviews[0]) as $rv | ($comments[0]) as $cm
| (($p.head.repo.full_name // "") != $p.base.repo.full_name) as $fork
| (
    if $p.state != "open" or ($p.merged // false) then {skip: "closed or merged"}
    elif $p.draft then {skip: "draft"}
    elif $p.user.login == $me then
      if ($fix_enabled | not) then {skip: "fix disabled"}
      elif $fork then {skip: "own PR from a fork, cannot push"}
      else
        ([$rv[] | select(.user.login != $me and .state == "CHANGES_REQUESTED")] | max_by(.id)) as $cr
        | ([$cm[] | select(.user.login != $me)] | max_by(.id)) as $c
        | if $cr == null and $c == null then {skip: "nothing to address"}
          else {
            kind: "fix",
            key: "fix|\($repo)|\($p.number)|r\($cr.id // 0)-c\($c.id // 0)",
            cr: ($cr != null),
            who: ([$cr.user.login, $c.user.login] | map(select(. != null)) | unique | join(", "))
          } end
      end
    elif $reason == "review_requested" then
      if ($review_enabled | not) then {skip: "review disabled"}
      elif $fork and ($allow_forks | not) then {skip: "fork PR, allow_forks is off"}
      else {kind: "review", key: "review|\($repo)|\($p.number)|\($p.head.sha)", who: $p.user.login}
      end
    else {skip: "not actionable (reason: \($reason))"}
    end
  )
| . + {
    repo: $repo, number: $p.number, head: $p.head.sha, branch: $p.head.ref,
    title: $p.title, url: $p.html_url, author: $p.user.login
  }
