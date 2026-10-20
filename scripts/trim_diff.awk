# trim_diff.awk: shrink a unified diff for the reviewer. Usage: NOISE=<ere> awk -v cap=<bytes> -f trim_diff.awk diff.patch
# Generated, lock, vendored and minified files (NOISE matched against the file name) and every file past the
# byte cap are replaced by a one-line stub; nothing is hidden silently, the stub says what to do.
# Prints "noise=N over=M" to stderr. ponytail: files are kept in diff order until the cap, not ranked by importance.
function flush(   n) {
  if (name == "") { printf "%s", buf; return }
  n = length(buf)
  if (name ~ ENVIRON["NOISE"]) { print "diff --git " hdr "\n# skipped: generated, lock or vendored file (" lines " lines); read it in the checkout only if it matters"; noise++ }
  else if (used + n > cap) { print "diff --git " hdr "\n# omitted: diff size cap reached (" lines " lines); read this file in the checkout (git diff against the base)"; over++ }
  else { printf "%s", buf; used += n }
}
/^diff --git / {
  flush(); buf = $0 "\n"; lines = 1; hdr = substr($0, 12)
  name = hdr; sub(/^.* b\//, "", name); next
}
{ buf = buf $0 "\n"; lines++ }
END { flush(); printf "noise=%d over=%d\n", noise, over > "/dev/stderr" }
