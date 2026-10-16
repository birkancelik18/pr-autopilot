# One trust rule, shared by classify.jq (what starts a fix) and job.sh (what reaches the fix model).
# Input: {login, assoc}. A trusted voice is me; or, unless listed in ignore_authors, a known review bot
# (review_bots, e.g. CodeRabbit), or a person (not "[bot]") who is OWNER, MEMBER or COLLABORATOR or is
# listed in trusted_commenters. Any other bot is not: it can relay a stranger.
def tvoice($me; $ignore; $review_bots; $trusted):
  .login == $me or (.login | IN($ignore[]) | not) and ((.login | IN($review_bots[]))
    or (.login | endswith("[bot]") | not) and ((.assoc // "NONE" | IN("OWNER", "MEMBER", "COLLABORATOR")) or (.login | IN($trusted[]))));
