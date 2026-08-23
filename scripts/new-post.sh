#!/bin/bash
# new-post.sh — scaffold a Hugo post bundle on the laptop.
#
# The WSL equivalent of the Obsidian _templates/new-post.md template, so posts
# created on either device get identical front matter — including
# `relative = true`, without which og:image resolves against the site root and
# social cards render with no banner.
#
# Usage:
#   ./scripts/new-post.sh "My Post Title"
#   ./scripts/new-post.sh "My Post Title" --tags hugo,git --banner ~/Pictures/x.png
#   ./scripts/new-post.sh "My Post Title" --slug short-name
#   ./scripts/new-post.sh "My Post Title" --publish
#
# Posts are created as draft = true, so an unfinished post can be committed
# safely. Set draft = false (or use --publish) when it is ready to go live.
#
# Options:
#   --slug NAME      Folder name instead of one derived from the title. Keeps
#                    the URL short and stable when the title is long, and lets
#                    you retitle later without changing the URL.
#   --tags a,b,c     Comma-separated tags
#   --banner FILE    Copy FILE into the bundle as banner.png
#   --publish        Create with draft = false — goes live on the next push

set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"

TITLE=""
SLUG_OVERRIDE=""
TAGS=""
BANNER=""
DRAFT="true"

while [ $# -gt 0 ]; do
    case "$1" in
        --slug)   SLUG_OVERRIDE="${2:?--slug needs a value}"; shift 2 ;;
        --tags)   TAGS="${2:?--tags needs a value}"; shift 2 ;;
        --banner) BANNER="${2:?--banner needs a path}"; shift 2 ;;
        --publish) DRAFT="false"; shift ;;
        --draft)   DRAFT="true";  shift ;;
        -h|--help)
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "ERROR: unknown option $1" >&2; exit 1 ;;
        *)
            if [ -z "$TITLE" ]; then TITLE="$1"; else
                echo "ERROR: unexpected argument '$1' (quote the title)" >&2; exit 1
            fi
            shift ;;
    esac
done

# The cover filename follows the banner's format: PNG suits flat graphics,
# JPEG is far smaller for photographic/AI-generated art.
COVER="banner.png"
if [ -n "$BANNER" ]; then
    case "${BANNER,,}" in
        *.jpg|*.jpeg) COVER="banner.jpg" ;;
    esac
fi

if [ -z "$TITLE" ]; then
    read -rp "Post title: " TITLE
    [ -n "$TITLE" ] || { echo "ERROR: title is required" >&2; exit 1; }
fi

# "My Post: Title!" -> "my-post-title". Normalise an explicit --slug the same
# way, so a stray space or capital cannot produce an odd URL.
SLUG_SOURCE=${SLUG_OVERRIDE:-$TITLE}
SLUG=$(printf '%s' "$SLUG_SOURCE" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
if [ -z "$SLUG" ]; then
    if [ -n "$SLUG_OVERRIDE" ]; then
        echo "ERROR: --slug '$SLUG_OVERRIDE' contains no usable characters" >&2
    else
        echo "ERROR: title produced an empty slug — pass --slug" >&2
    fi
    exit 1
fi
if [ -n "$SLUG_OVERRIDE" ] && [ "$SLUG" != "$SLUG_OVERRIDE" ]; then
    echo "note: slug normalised to '$SLUG'"
fi

DIR="content/posts/$(date +%Y-%m-%d)-$SLUG"
if [ -e "$DIR" ]; then
    echo "ERROR: $DIR already exists." >&2
    exit 1
fi

# TOML array: hugo,git -> 'hugo', 'git'
TAG_LINE="tags = []"
if [ -n "$TAGS" ]; then
    quoted=$(printf '%s' "$TAGS" | awk -F, '{
        for (i = 1; i <= NF; i++) {
            gsub(/^[ \t]+|[ \t]+$/, "", $i)
            if ($i != "") { printf "%s'\''%s'\''", (n++ ? ", " : ""), $i }
        }
    }')
    [ -n "$quoted" ] && TAG_LINE="tags = [$quoted]"
fi

# TOML strings: a literal 'single-quoted' string cannot contain an apostrophe
# and has no escape for one, so fall back to a "basic" string in that case.
esc_basic() {
    local s=${1//\\/\\\\}   # backslash first
    printf '%s' "${s//\"/\\\"}"
}
if [[ "$TITLE" == *"'"* ]]; then
    TITLE_TOML="\"$(esc_basic "$TITLE")\""
else
    TITLE_TOML="'$TITLE'"
fi
ALT_TOML="\"$(esc_basic "$TITLE")\""

mkdir -p "$DIR"
cat > "$DIR/index.md" <<EOF
+++
date = '$(date +%Y-%m-%dT%H:%M:%S%:z)'
draft = $DRAFT
title = $TITLE_TOML
$TAG_LINE

[params.cover]
  image = "$COVER"
  alt = $ALT_TOML
  relative = true
+++

EOF

echo "✓ created $DIR/index.md"

if [ -n "$BANNER" ]; then
    if [ ! -f "$BANNER" ]; then
        echo "ERROR: banner '$BANNER' not found — post created without one." >&2
        exit 1
    fi
    # Normalise to the 1200x630 / 1.91:1 shape social cards render at, so an
    # AI-generated 16:9 image is not cropped unpredictably by the platform.
    if command -v python3 >/dev/null 2>&1 \
       && python3 -c "import PIL" >/dev/null 2>&1; then
        printf '✓ banner  '
        "$(dirname "$0")/fit-banner.py" "$BANNER" "$DIR/$COVER"
    else
        cp "$BANNER" "$DIR/$COVER"
        echo "✓ copied banner  $DIR/$COVER (Pillow missing — not resized)"
    fi
else
    echo
    echo "WARNING: no banner yet — this post has no social card image."
    echo
    echo "  Add it with the fitter, not cp, so it gets sized to 1200x630 and"
    echo "  the full-resolution original is archived:"
    echo
    echo "      ./scripts/fit-banner.py /path/to/image.png $DIR/$COVER"
    echo
    echo "  A plain cp leaves whatever your image tool produced. ./publish.sh"
    echo "  would notice and offer to fit it, but 'git add/commit/push' will"
    echo "  not — CI only warns, so an oversized banner publishes silently."
    if [ "$DRAFT" = "false" ]; then
        echo
        echo "  This post is draft = false, so check-posts.sh FAILS until"
        echo "  $COVER exists — locally and in CI."
    fi
fi

echo
if [ "$DRAFT" = "true" ]; then
    echo
    echo "This post is draft = true — it will NOT appear on the live site."
    echo "Set draft = false in the front matter when it is ready."
fi

echo
echo "Write:    \$EDITOR $DIR/index.md"
echo "Preview:  hugo server -D   ->  http://localhost:1313/"
echo "Publish:  ./publish.sh \"new post - $SLUG\""
