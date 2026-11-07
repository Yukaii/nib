#!/usr/bin/env bash
# Guards the workflow in AGENTS.md: size limits and task file shape.
set -euo pipefail
cd "$(dirname "$0")/.."
errors=0
fail() { echo "workflow: $*" >&2; errors=$((errors + 1)); }

limit() { [[ -f $1 ]] || { [[ $1 == docs/* ]] && return; fail "$1 missing"; return; }
  local n; n=$(wc -l <"$1"); ((n <= $2)) || fail "$1: $n lines > $2"; }
limit AGENTS.md 200
limit PLAN.md 120
limit docs/architecture.md 150
for f in docs/decisions/*.md; do [[ -e $f ]] && limit "$f" 60; done

for f in tasks/*.md; do
  [[ -e $f ]] || continue
  name=$(basename "$f")
  [[ $name == _template.md ]] && continue
  [[ $name =~ ^([0-9]{4})-[a-z0-9]+(-[a-z0-9]+)*\.md$ ]] || { fail "$f: bad name"; continue; }
  id=${BASH_REMATCH[1]}
  grep -qE "^id: \"?$id\"?$" "$f" || fail "$f: id must be $id"
  grep -qE '^status: (todo|doing|review)$' "$f" || fail "$f: status must be todo|doing|review"
  grep -qE '^milestone: M[0-9]+$' "$f" || fail "$f: milestone must look like M1"
  grep -qE '^depends: \[' "$f" || fail "$f: depends must be a list"
  for s in Goal Context Acceptance "Out of scope" Handoff; do
    grep -qE "^## $s\s*$" "$f" || fail "$f: missing ## $s"
  done
done
((errors == 0)) || exit 1
echo "workflow: ok"
