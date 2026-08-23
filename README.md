# Hugo Blog Pipeline

A complete, opinionated blogging pipeline for Hugo + GitHub Pages. Write from any device (iPhone, Linux desktop, WSL), push to GitHub, and let CI validate and deploy automatically.

No CMS. No database. No block editor. Just markdown, git, and one command to publish.

## What You Get

- **Page bundle scaffolding** with correct front matter (`new-post.sh`)
- **Banner fitting** to 1200×630 for social cards — crop, pad, or auto, with original archiving (`fit-banner.py`)
- **CI validation gate** that fails the build on broken `og:image` before it reaches the live site (`check-posts.sh`)
- **iPhone workflow** via Obsidian + Obsidian Git + Templater
- **One-command publish** with pull, scan, validate, build, push (`publish.sh`)

## Quick Start

```bash
# 1. Create your Hugo site (or clone an existing one)
hugo new site my-blog && cd my-blog && git init

# 2. Add this pipeline
curl -sL https://github.com/yourname/hugo-blog-pipeline/archive/main.tar.gz \
  | tar xz --strip-components=1 --wildcards \
    '*/scripts/*' '*/.github/*' '*/publish.sh' '*/_templates/*' \
    '*/.gitattributes' '*/.gitignore'

# 3. Add a theme (PaperMod shown, any theme works)
git submodule add https://github.com/adityatelange/hugo-PaperMod.git themes/papermod

# 4. Configure hugo.toml (see hugo.toml.example)
cp hugo.toml.example hugo.toml
# Edit: baseURL, title, description, author

# 5. Create your first post
./scripts/new-post.sh "My First Post" --slug first-post

# 6. Push and deploy
git add -A && git commit -m "initial setup"
git remote add origin git@github.com:yourname/my-blog.git
git push -u origin main
```

Then go to **Settings → Pages → Source → GitHub Actions** in your repo.

## Architecture

Two git clones, one repo. Git is the only sync mechanism.

```
iPhone (Obsidian + Obsidian Git)          Linux / WSL
┌────────────────────────────┐            ┌────────────────────────────┐
│ vault = git clone          │            │ ~/my-blog = git clone      │
│   content/posts/           │            │   content/posts/           │
│     YYYY-MM-DD-slug/       │            │     YYYY-MM-DD-slug/       │
│       index.md             │            │       index.md             │
│       banner.jpg           │            │       banner.jpg           │
└─────────────┬──────────────┘            └─────────────┬──────────────┘
              │ push/pull (HTTPS + PAT)                 │ push/pull (SSH)
              └──────────────────┬──────────────────────┘
                                 ▼
                    GitHub: your-blog repo
                    Actions: validate → build → deploy
                    Pages:   live site
```

> **Rule:** If a copy of your content is not a git clone, it will eventually overwrite one that is.

## Scripts

### `scripts/new-post.sh`

Scaffold a Hugo page bundle with correct front matter.

```bash
./scripts/new-post.sh "My Post Title"
./scripts/new-post.sh "My Post Title" --tags hugo,git --banner ~/img.png
./scripts/new-post.sh "My Post Title" --slug short-name --publish
```

| Flag | Effect |
|------|--------|
| `--tags a,b,c` | Comma-separated tags |
| `--banner FILE` | Copy + fit to 1200×630 (archives original) |
| `--slug NAME` | Custom URL slug (default: derived from title) |
| `--publish` | Set `draft = false` (default is `true`) |

### `scripts/fit-banner.py`

Normalise a banner image for social cards (1200×630, 1.91:1).

```bash
# Single image
./scripts/fit-banner.py ~/Downloads/ai-art.png content/posts/my-post/banner.jpg

# Scan all posts — find and fix non-compliant banners
./scripts/fit-banner.py --scan --dry-run    # report only
./scripts/fit-banner.py --scan              # archive, fit, rewrite front matter
```

- **crop** when source ratio is near target (e.g. 16:9)
- **pad** when it's far off (e.g. 3:2), using sampled border colour
- **never upscales** — small sources stay sharp
- **archives originals** to `banners/originals/` (gitignored, local only)
- Outputs JPEG for photographic art, PNG for flat graphics (follows input extension or output extension)

### `scripts/check-posts.sh`

CI validation gate — runs before `hugo build`.

| Check | Result |
|-------|--------|
| Cover file missing | **FAIL** — deploy blocked |
| `relative = true` missing | **FAIL** — deploy blocked |
| Banner > 500KB | warn |
| Banner outside 1.7–2.1:1 | warn |
| Banner < 600px wide | warn |
| `draft = true` | listed (never fails) |

### `publish.sh`

Optional convenience wrapper around plain git.

```bash
./publish.sh "new post - my title"
```

Sequence: `git pull --rebase` → banner scan (asks before changing) → validate → build → commit → push.

Equivalent plain git:
```bash
git pull --rebase origin main
git add -A && git commit -m "new post - my title" && git push origin main
```

## iPhone Setup (Obsidian + Obsidian Git)

1. Install Obsidian from the App Store
2. Install the **Git** community plugin
3. Clone your blog repo via HTTPS + Personal Access Token
4. Install the **Templater** community plugin
5. Set Template folder to `_templates`
6. Settings → Files & Links:
   - **Use `[[Wikilinks]]`**: OFF (emit standard `![](img.png)`)
   - **Default location for new attachments**: Same folder as current file

Create a post: New note → Templater → `new-post` → prompts for title and tags, creates the page bundle.

Publish: Command palette → **Obsidian Git: Commit and Sync**

See `_templates/new-post.md` for the full Templater script.

## Front Matter

Every post uses a page bundle (`content/posts/YYYY-MM-DD-slug/index.md`) with this front matter:

```toml
+++
date = '2026-08-23T10:00:00-04:00'
draft = false
title = 'My Post Title'
tags = ['hugo', 'git']

[params.cover]
  image = "banner.jpg"
  alt = "My Post Title"
  relative = true
+++
```

**`relative = true` is critical.** Without it, PaperMod resolves `og:image` against the site root instead of the page bundle — the card image 404s while the page looks fine. This is the bug the CI gate exists to catch.

## Social Card Sizing

- **Target**: 1200×630 (1.91:1) — the Open Graph standard
- **Acceptable**: anything 1.7:1 to 2.1:1; platforms centre-crop the difference
- **16:9 AI art**: works fine, minor crop on top/bottom edges
- **3:2 AI art**: padded by `fit-banner.py` to avoid cutting content

Keep banners under 500KB. Use JPEG for photographic art (a 1.5MB PNG becomes ~100KB JPEG with no visible loss).

### Testing a card

```bash
# Check the meta tags
curl -s <post-url> | grep -oE '<meta (property="og:image"|name=twitter:image)[^>]*>'

# Confirm the image URL returns 200
curl -s -o /dev/null -w "%{http_code}\n" <image-url>
```

Never test by re-sharing the same link — platforms cache cards for ~1 week, including failures. Use `?v=2` for a fresh scrape.

## CI Workflow

`.github/workflows/hugo.yml` runs on every push to `main`:

1. Checkout (with submodules for the theme)
2. **Validate posts** — `scripts/check-posts.sh`
3. **Build** — `hugo --minify`
4. **Deploy** — GitHub Pages

A broken cover or missing `relative = true` fails step 2 and blocks deploy, regardless of which device pushed.

## Line Endings

`.gitattributes` enforces LF everywhere. Without it, a script committed from Windows arrives in CI with CRLF and fails with `bad interpreter`.

## Requirements

- Hugo (any recent version, extended recommended)
- Python 3 + Pillow (for `fit-banner.py`)
- Git
- A GitHub repo with Pages enabled (source: GitHub Actions)

## License

MIT
