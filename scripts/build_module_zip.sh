#!/bin/sh
# Build the published Terraform module zip from a commit, reproducibly, and print its sha256.
# The zip holds every tracked file of aws/terraform at its root (main.tf runs scripts/ at plan
# time), except the module's own tests, examples and .gitignore.
# Usage: scripts/build_module_zip.sh <commit> <out.zip>
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <commit> <out.zip>" >&2; exit 2; }
commit=$1; out=$2
# --mtime pins every entry's date to the commit's, so two builds of one commit are byte-identical.
# git archive gained --mtime in 2.40; an older git would stamp the current time, or fail.
version=$(git --version | sed -n 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
set -- $version
if [ "${1:-0}" -lt 2 ] || { [ "${1:-0}" -eq 2 ] && [ "${2:-0}" -lt 40 ]; }; then
  echo "build_module_zip.sh needs git 2.40 or later (git archive --mtime); found: $(git --version)" >&2
  exit 2
fi
# A zip stores local time (DOS dates), so the builder's time zone would change the bytes.
export TZ=UTC
files=$(git ls-tree -r --name-only "$commit:aws/terraform" | grep -v -e '^tests/' -e '^examples/' -e '^\.gitignore$')
# shellcheck disable=SC2086 # one module path per word; none contains a space
git archive --format=zip --mtime="$(git log -1 --format=%cI "$commit")" -o "$out" "$commit:aws/terraform" $files
sha256sum "$out"
