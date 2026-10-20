#!/bin/sh
# Build the published Terraform module zip from a commit, reproducibly, and print its sha256.
# The zip holds aws/terraform's module files at its root, plus the script main.tf runs at plan time.
# Usage: scripts/build_module_zip.sh <commit> <out.zip>
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <commit> <out.zip>" >&2; exit 2; }
commit=$1; out=$2
git archive --format=zip --mtime="$(git log -1 --format=%cI "$commit")" -o "$out" "$commit:aws/terraform" \
  main.tf variables.tf outputs.tf versions.tf identifiers.tf README.md scripts/existing_logging.sh
sha256sum "$out"
