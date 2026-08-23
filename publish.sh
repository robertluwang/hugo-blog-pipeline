#!/bin/bash
# publish.sh — optional convenience wrapper: validate, build, commit, push.
#
# Entirely optional. Plain git does the same job:
#   git pull --rebase origin main
#   git add -A && git commit -m "msg" && git push origin main
#
# The value here is fast local feedback: it runs the same checks CI runs, so a
# broken cover is caught before you push instead of failing the pipeline.
# The authoritative gate is scripts/check-posts.sh in .github/workflows/hugo.yml,
# which also covers posts pushed from a phone that never runs this script.
#
# Usage: ./publish.sh [commit message]

set -euo pipefail

cd "$(cd "$(dirname "$0")" && pwd)"

HUGO="${HUGO_BIN:-$(command -v hugo || echo ../hugo)}"

echo "==> Pulling latest from origin"
if ! git pull --rebase origin main; then
    echo >&2
    echo "ERROR: pull/rebase failed — resolve the conflict, then re-run." >&2
    echo "       git status ; git rebase --continue   (or: git rebase --abort)" >&2
    exit 1
fi

echo "==> Checking banners"
# Report only. A banner that is heavy or the wrong shape still publishes, so
# this must not change files behind your back — it asks first.
scan_rc=0
./scripts/fit-banner.py --scan --dry-run || scan_rc=$?
if [ "$scan_rc" -eq 2 ]; then
    if [ -t 0 ]; then
        read -rp "Fit these banners now? Originals are archived first. [y/N] " reply
        case "$reply" in
            y|Y|yes|YES)
                ./scripts/fit-banner.py --scan
                ;;
            *)
                echo "Skipped — publishing with the banners as they are."
                ;;
        esac
    else
        echo "Not a terminal — skipping. Run ./scripts/fit-banner.py --scan to fit them."
    fi
elif [ "$scan_rc" -ne 0 ]; then
    echo "ERROR: banner scan failed (exit $scan_rc)." >&2
    exit 1
fi

echo "==> Validating posts"
./scripts/check-posts.sh

echo "==> Building"
if ! "$HUGO" --minify --quiet; then
    echo "ERROR: Hugo build failed. Nothing was committed." >&2
    exit 1
fi

git add -A
if git diff --cached --quiet; then
    echo "Nothing to publish."
    exit 0
fi

echo "==> Changes to publish"
git diff --cached --stat | cat

git commit -m "${1:-update blog posts}"
git push origin main

echo "✓ Published. Site live in ~60 seconds."
