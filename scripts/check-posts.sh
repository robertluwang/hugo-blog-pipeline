#!/bin/bash
# check-posts.sh — validate post front matter before the site is built.
#
# Catches failures that `hugo build` does NOT catch, because they produce
# valid HTML pointing at the wrong place:
#
#   1. A cover declared in front matter whose image file is missing
#      -> og:image / twitter:image 404 and social cards render with no banner.
#   2. A page-bundle cover without `relative = true`
#      -> PaperMod resolves the image against the SITE ROOT instead of the
#         page bundle, so og:image 404s while the page itself looks fine.
#
# Runs in CI so it protects posts pushed from any device, including phones
# that commit straight to GitHub. Also runnable by hand from anywhere.
#
# Exit 0 = clean, 1 = problems found.

set -uo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"

# Banner quality: a heavy or oddly-shaped cover still deploys, it just makes a
# worse card - so warn, never fail. File size needs no dependencies; dimensions
# need Pillow, which may be absent on a CI runner, so that part degrades to a
# no-op rather than erroring.
MAX_COVER_KB=500
have_pillow=0
if command -v python3 >/dev/null 2>&1 && python3 -c "import PIL" >/dev/null 2>&1; then
    have_pillow=1
fi

check_cover_quality() {
    local file=$1 slug=$2
    local kb=$(( ($(stat -c%s "$file") + 1023) / 1024 ))
    if [ "$kb" -gt "$MAX_COVER_KB" ]; then
        echo "WARN   $slug: cover is ${kb}KB (> ${MAX_COVER_KB}KB) — slow for every scrape."
        echo "       Fix: ./scripts/fit-banner.py $file ${file%.*}.jpg"
        warnings=$((warnings + 1))
    fi
    [ "$have_pillow" -eq 1 ] || return 0
    local dims
    dims=$(python3 -c "
from PIL import Image
import sys
w, h = Image.open(sys.argv[1]).size
print(w, h, round(w / h, 2))
" "$file" 2>/dev/null) || return 0
    set -- $dims
    local w=$1 h=$2 ratio=$3
    if awk "BEGIN{exit !($ratio < 1.7 || $ratio > 2.1)}"; then
        echo "WARN   $slug: cover is ${w}x${h} (${ratio}:1) — cards render near 1.91:1."
        echo "       Platforms will centre-crop; edges may be cut. Fix: ./scripts/fit-banner.py"
        warnings=$((warnings + 1))
    elif [ "$w" -lt 600 ]; then
        echo "WARN   $slug: cover is only ${w}px wide — may look soft in previews."
        warnings=$((warnings + 1))
    fi
}

NOW=$(date +%s)
problems=0
warnings=0
checked=0
drafts=0

# Front matter = everything above the closing +++ (TOML) or --- (YAML).
frontmatter() {
    awk 'NR==1 && /^(\+\+\+|---)[[:space:]]*$/ {d=substr($0,1,3); next}
         d && $0 ~ "^" (d=="+++" ? "\\+\\+\\+" : "---") "[[:space:]]*$" {exit}
         d {print}' "$1"
}

for post in content/posts/*/index.md; do
    [ -e "$post" ] || continue
    dir=$(dirname "$post")
    slug=$(basename "$dir")
    checked=$((checked + 1))

    fm=$(frontmatter "$post")

    # Drafts are excluded from the build, so an incomplete draft (e.g. a
    # scaffolded post whose banner isn't in place yet) must not fail CI.
    if printf '%s\n' "$fm" | grep -qP '^\s*draft\s*=\s*true'; then
        # Listed, not silent: a post left as a draft by accident never appears
        # on the live site and gives no other signal that it is missing.
        echo "DRAFT  $slug: draft = true — will NOT be published."
        drafts=$((drafts + 1))
        continue
    fi

    cover=$(printf '%s\n' "$fm" | grep -oP '^\s*image\s*=\s*"\K[^"]+' | head -1)

    if [ -n "$cover" ]; then
        case "$cover" in
            http://*|https://*)
                # External cover: nothing local to verify.
                ;;
            *)
                if [ ! -f "$dir/$cover" ]; then
                    echo "ERROR  $slug: cover \"$cover\" declared but $dir/$cover is missing."
                    echo "       og:image would 404 and the social card would show no banner."
                    echo "       Fix: add the image, or remove the [params.cover] block."
                    problems=$((problems + 1))
                fi
                if [ -f "$dir/$cover" ]; then
                    check_cover_quality "$dir/$cover" "$slug"
                fi
                if ! printf '%s\n' "$fm" | grep -qP '^\s*relative\s*=\s*true'; then
                    echo "ERROR  $slug: cover set but 'relative = true' missing from [params.cover]."
                    echo "       og:image would resolve against the site root, not the page bundle."
                    echo "       Fix: add 'relative = true' under [params.cover]."
                    problems=$((problems + 1))
                fi
                ;;
        esac
    fi

    # Future-dated posts are excluded from the build. Legitimate for
    # scheduling, so warn rather than fail.
    pdate=$(printf '%s\n' "$fm" | grep -oP "^\s*date\s*=\s*['\"]\K[^'\"]+" | head -1)
    if [ -n "$pdate" ]; then
        if ts=$(date -d "$pdate" +%s 2>/dev/null); then
            if [ "$ts" -gt "$NOW" ]; then
                echo "WARN   $slug: dated in the future ($pdate) — Hugo will skip it."
                warnings=$((warnings + 1))
            fi
        fi
    fi
done

# Non-bundle posts can't use relative covers; flag them so they aren't
# silently validated by the bundle rules above.
for post in content/posts/*.md; do
    [ -e "$post" ] || continue
    [ "$(basename "$post")" = "_index.md" ] && continue
    if frontmatter "$post" | grep -qP '^\s*image\s*=\s*"'; then
        echo "WARN   $(basename "$post"): cover on a non-bundle post — verify og:image by hand."
        warnings=$((warnings + 1))
    fi
done

echo
echo "Checked $checked post(s) ($drafts draft(s) skipped): $problems error(s), $warnings warning(s)."

if [ "$problems" -gt 0 ]; then
    echo "FAILED — fix the errors above before publishing."
    exit 1
fi

echo "PASSED"
