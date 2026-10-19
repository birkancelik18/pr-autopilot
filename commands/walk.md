---
description: Walk through a PR's diff block by block in this session, ask questions, then choose what to post
argument-hint: <PR number, URL or owner/repo#N>
---

Walk the user through PR `$ARGUMENTS`. Work in this session; nothing goes to GitHub until the user picks at the end.

1. Resolve the PR: `gh pr view $ARGUMENTS --json url,number,title,headRefOid,state`. Take `owner/repo` from the URL. Call `headRefOid` the walked sha.
2. Read the diff at that sha (`gh pr diff` and the files at the head, e.g. `gh api repos/<owner/repo>/contents/<path>?ref=<sha>`), never an older checkout. Load the private draft if there is one: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/walk.sh" draft <owner/repo> <n>` (exit 1 means none; walk anyway). If its `head` is not the walked sha, say the draft is of an older commit and treat its findings as unverified.
3. Walk the diff in source order, one logical block at a time (a guard, a function, a query). Per block: one or two plain sentences, what it does and why it matters, with a clickable `path:line` cite. Never paste the code. Show a draft finding right next to the block it belongs to, after checking it against the real code. Then stop and ask if they want to continue or ask something. Answer questions from the real code at the head.
4. At the end show a checklist (each block, ok or flagged) and ask what to post: approve, request changes, comment or nothing, and which findings to include. Write the body in the user's voice, short, no headings, one blocker per line with `path:line` and the concrete failure.
5. Post only on their explicit pick, and only via `bash "${CLAUDE_PLUGIN_ROOT}/scripts/walk.sh" post <owner/repo> <n> <walked sha> <APPROVE|REQUEST_CHANGES|COMMENT> <body file>`. It posts pinned to the walked sha and refuses if the head moved (exit 3). Then tell the user the head moved, show what changed (`gh api repos/<owner/repo>/compare/<walked sha>...<new sha>`), offer to walk just the new part, and post nothing until they pick again.
