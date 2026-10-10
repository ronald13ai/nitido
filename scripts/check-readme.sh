#!/bin/zsh
# Fails while README.md is not ready to publish: a "(fill in)" left in it, an image it links that git does not track
# (it would show broken on GitHub), or an em dash. Run it before making the repository public.
set -euo pipefail
cd "$(dirname "$0")/.."
problems=0
if grep -n "(fill in" README.md; then
  echo "check-readme: README.md still has figures to fill in (the lines above)." >&2
  problems=1
fi
for image in $(grep -oE '!\[[^]]*\]\([^)]+\)' README.md | sed -E 's/^.*\]\(//; s/\)$//'); do
  if ! git ls-files --error-unmatch -- "$image" > /dev/null 2>&1; then
    echo "check-readme: README.md shows $image, which git does not track." >&2
    problems=1
  fi
done
emdash=$(printf '\342\200\224')   # U+2014, spelled as its UTF-8 bytes so this script holds none
if grep -n "$emdash" README.md; then
  echo "check-readme: README.md has an em dash (the lines above)." >&2
  problems=1
fi
if [[ $problems -ne 0 ]]; then exit 1; fi
echo "check-readme: README.md is ready to publish."
