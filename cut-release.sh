#!/bin/sh
# Publish a GitHub release from the latest successful CI build.
#
#   ./cut-release.sh v0.2.2 ["release notes"]
#
# Takes the msx2-pocket artifact from the most recent successful Compile Core
# run on the current branch, zips it into an SD-card package, and attaches it
# to a new release.
set -e
cd "$(dirname "$0")"

TAG="$1"
NOTES="$2"
[ -n "$TAG" ] || { echo "usage: $0 <tag> [notes]" >&2; exit 1; }

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
BRANCH=$(git rev-parse --abbrev-ref HEAD)

RUN=$(gh run list --repo "$REPO" --workflow compile.yml --branch "$BRANCH" \
        --status success --limit 1 --json databaseId --jq '.[0].databaseId')
[ -n "$RUN" ] || { echo "no successful build on $BRANCH" >&2; exit 1; }
echo "using run $RUN on $BRANCH"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gh run download "$RUN" --repo "$REPO" --name msx2-pocket --dir "$WORK/sd"
(cd "$WORK/sd" && zip -qr "$WORK/msx2-pocket-sdcard.zip" .)

gh release create "$TAG" --repo "$REPO" --target "$BRANCH" \
    --title "MSX2 for Analogue Pocket $TAG" \
    --notes "${NOTES:-Build from CI run $RUN.

Unzip onto the Pocket SD card root, overwriting previous files.
Cartridge .rom files go in Assets/msx/common/.}" \
    "$WORK/msx2-pocket-sdcard.zip"
