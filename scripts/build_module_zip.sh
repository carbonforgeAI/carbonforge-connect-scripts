#!/bin/sh
# Build the published Terraform module zip from a commit, reproducibly, and print its sha256.
# The zip holds aws/terraform's module files at its root, plus the script main.tf runs at plan time.
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
git archive --format=zip --mtime="$(git log -1 --format=%cI "$commit")" -o "$out" "$commit:aws/terraform" \
  main.tf variables.tf outputs.tf versions.tf identifiers.tf README.md scripts/existing_logging.sh
sha256sum "$out"
