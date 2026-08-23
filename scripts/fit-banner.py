#!/usr/bin/env python3
"""fit-banner.py — normalise a banner image for social cards.

Social platforms render link previews at roughly 1.91:1 (1200x630). An image
with a different ratio gets centre-cropped by the platform, and you do not get
to choose where the crop lands - titles at the top or bottom edge are the usual
casualties.

Modes:
  crop  Scale to cover 1200x630 and centre-crop. Minimal loss when the source
        ratio is already close (e.g. 16:9), but cuts content when it is not.
  pad   Scale to fit inside 1200x630 and pad with a colour sampled from the
        image border. Loses nothing, adds bars.
  auto  crop when the source ratio is near the target, pad otherwise.
        (default)

The full-resolution source is copied to banners/originals/ first. AI-generated
images cannot usually be regenerated identically, so the downscaled card image
must never be the only copy. Disable with --no-archive.

Usage:
  ./scripts/fit-banner.py in.png out.png             # one image
  ./scripts/fit-banner.py in.png out.png --mode pad
  ./scripts/fit-banner.py --scan --dry-run           # what needs adjusting
  ./scripts/fit-banner.py --scan                     # adjust every post

--scan checks every post's cover, skips the ones already within limits, and for
the rest archives the original, writes a fitted banner.jpg, updates the front
matter and removes the old file. Useful after publishing from a phone, where
nothing resizes the image.

Exit codes: 0 = clean or applied, 2 = --dry-run found work pending.
"""

import argparse
import glob
import hashlib
import os
import re
import shutil
import sys

try:
    from PIL import Image, ImageStat
except ImportError:
    sys.exit("ERROR: Pillow is required — pip install pillow")

TARGET_W, TARGET_H = 1200, 630
TARGET_RATIO = TARGET_W / TARGET_H          # 1.905
# Within this much of the target, cropping costs little; beyond it, pad instead.
CROP_TOLERANCE = 0.15
# Full-resolution sources are archived here. AI-generated images usually cannot
# be regenerated identically, so the downscaled copy must not be the only one.
ARCHIVE_DIR = "banners/originals"


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def archive_original(src, dst, archive_dir):
    """Keep the full-resolution source. Returns the archived path, or None."""
    os.makedirs(archive_dir, exist_ok=True)

    # Name it after the post it belongs to, not after whatever the image tool
    # happened to call the file, so the archive maps 1:1 to posts:
    #   2026-08-23-my-post-banner.png
    parts = os.path.abspath(dst).split(os.sep)
    slug = ""
    if "posts" in parts:
        i = parts.index("posts")
        if i + 1 < len(parts) - 1:
            slug = parts[i + 1]
    ext = os.path.splitext(src)[1].lower()
    name = f"{slug}-banner{ext}" if slug else os.path.basename(src)

    target = os.path.join(archive_dir, name)
    if os.path.exists(target):
        if md5(target) == md5(src):
            return target                      # already archived, nothing to do
        stem, ext = os.path.splitext(name)
        n = 2
        while os.path.exists(os.path.join(archive_dir, f"{stem}-{n}{ext}")):
            n += 1
        target = os.path.join(archive_dir, f"{stem}-{n}{ext}")

    shutil.copy2(src, target)
    return target


def border_colour(im):
    """Median colour of a thin frame around the image — a good pad colour."""
    w, h = im.size
    edge = max(2, min(w, h) // 50)
    strips = [
        im.crop((0, 0, w, edge)),
        im.crop((0, h - edge, w, h)),
        im.crop((0, 0, edge, h)),
        im.crop((w - edge, 0, w, h)),
    ]
    px = [round(c) for s in strips for c in ImageStat.Stat(s).median[:3]]
    n = len(px) // 3
    return tuple(sum(px[i::3]) // n for i in range(3))


def fit(im, mode, allow_upscale=False):
    ratio = im.size[0] / im.size[1]

    if mode == "auto":
        mode = "crop" if abs(ratio - TARGET_RATIO) <= CROP_TOLERANCE else "pad"

    # Upscaling adds no detail and softens the image. If the source is smaller
    # than 1200x630, keep its resolution and only correct the aspect ratio.
    out_w, out_h = TARGET_W, TARGET_H
    if not allow_upscale and (im.size[0] < TARGET_W or im.size[1] < TARGET_H):
        if mode == "crop":
            out_w = min(im.size[0], round(im.size[1] * TARGET_RATIO))
        else:
            out_w = min(TARGET_W, im.size[0])
        out_h = max(1, round(out_w / TARGET_RATIO))

    if mode == "crop":
        scale = max(out_w / im.size[0], out_h / im.size[1])
        resized = im.resize(
            (max(out_w, round(im.size[0] * scale)),
             max(out_h, round(im.size[1] * scale))),
            Image.LANCZOS,
        )
        left = (resized.size[0] - out_w) // 2
        top = (resized.size[1] - out_h) // 2
        return resized.crop((left, top, left + out_w, top + out_h)), mode

    scale = min(out_w / im.size[0], out_h / im.size[1])
    resized = im.resize(
        (max(1, round(im.size[0] * scale)), max(1, round(im.size[1] * scale))),
        Image.LANCZOS,
    )
    canvas = Image.new("RGB", (out_w, out_h), border_colour(im))
    canvas.paste(
        resized,
        ((out_w - resized.size[0]) // 2, (out_h - resized.size[1]) // 2),
    )
    return canvas, mode


def frontmatter_cover(path):
    """Return (cover_filename, line_index, lines) for a post's front matter."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines(keepends=True)
    if not lines or lines[0].strip() not in ("+++", "---"):
        return None, None, lines
    delim = lines[0].strip()
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == delim:
            break
        m = re.match(r'^\s*image\s*=\s*"([^"]+)"', line)
        if m:
            return m.group(1), i, lines
    return None, None, lines


def needs_work(path, max_kb, lo, hi):
    """Why this cover should be reprocessed, or None if it is fine."""
    kb = os.path.getsize(path) / 1024
    reasons = []
    if kb > max_kb:
        reasons.append(f"{kb:.0f}KB")
    try:
        with Image.open(path) as im:
            w, h = im.size
        ratio = w / h
        if not (lo <= ratio <= hi):
            reasons.append(f"{w}x{h} ({ratio:.2f}:1)")
    except Exception:
        return None
    return ", ".join(reasons) if reasons else None


def scan(args):
    root = repo_root()
    posts = sorted(glob.glob(os.path.join(root, "content", "posts", "*", "index.md")))
    archive_dir = args.archive_dir or os.path.join(root, ARCHIVE_DIR)
    todo = 0

    for post in posts:
        d = os.path.dirname(post)
        slug = os.path.basename(d)
        cover, idx, lines = frontmatter_cover(post)
        if not cover or cover.startswith(("http://", "https://")):
            continue
        src = os.path.join(d, cover)
        if not os.path.isfile(src):
            print(f"  MISSING  {slug}: {cover} not found — fix before publishing")
            continue

        why = needs_work(src, args.max_kb, args.min_ratio, args.max_ratio)
        if not why:
            continue

        todo += 1
        # Photographic AI art is far smaller as JPEG; that is the usual case for
        # an oversized banner, so scan mode standardises on it.
        dst = os.path.join(d, "banner.jpg")
        print(f"  {slug}: {why}")
        if args.dry_run:
            print(f"    would archive {cover} and write banner.jpg")
            continue

        if not args.no_archive:
            kept = archive_original(src, dst, archive_dir)
            print(f"    archived  {os.path.relpath(kept, root)}")

        with Image.open(src) as im:
            out, used = fit(im.convert("RGB"), args.mode, args.allow_upscale)
        out.save(dst, quality=88, optimize=True, progressive=True)
        print(f"    written   {os.path.relpath(dst, root)} "
              f"({os.path.getsize(dst)/1024:.0f}KB, {used})")

        if os.path.basename(dst) != cover:
            lines[idx] = re.sub(r'"[^"]+"', '"banner.jpg"', lines[idx], count=1)
            with open(post, "w", encoding="utf-8") as fh:
                fh.writelines(lines)
            os.remove(src)
            print(f"    updated   front matter -> banner.jpg, removed {cover}")

    if todo == 0:
        print("  nothing to adjust — all covers within limits")
        return 0
    if args.dry_run:
        # Exit 2 so a caller can tell "work pending" from "all clean" without
        # parsing this output.
        print(f"\n  {todo} banner(s) would be adjusted. Re-run without --dry-run.")
        return 2
    print(f"\n  {todo} banner(s) adjusted. Review with: git status")
    return 0


def main():
    ap = argparse.ArgumentParser(description="Fit a banner to 1200x630 for social cards.")
    ap.add_argument("src", nargs="?", help="source image (omit with --scan)")
    ap.add_argument("dst", nargs="?", help="output image (omit with --scan)")
    ap.add_argument("--scan", action="store_true",
                    help="check every post and adjust only the banners that need it")
    ap.add_argument("--dry-run", action="store_true",
                    help="with --scan, report what would change and stop")
    ap.add_argument("--max-kb", type=float, default=500,
                    help="size above which a cover is reprocessed (default: 500)")
    ap.add_argument("--min-ratio", type=float, default=1.7)
    ap.add_argument("--max-ratio", type=float, default=2.1)
    ap.add_argument("--mode", choices=("auto", "crop", "pad"), default="auto")
    ap.add_argument("--allow-upscale", action="store_true",
                    help="scale small sources up to 1200x630 (softens them)")
    ap.add_argument("--archive-dir", default=None,
                    help=f"where to keep full-resolution sources (default: {ARCHIVE_DIR})")
    ap.add_argument("--no-archive", action="store_true",
                    help="do not keep a copy of the source")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if args.scan:
        if args.src or args.dst:
            sys.exit("ERROR: --scan takes no src/dst arguments")
        sys.exit(scan(args))

    if not args.src or not args.dst:
        ap.error("src and dst are required unless --scan is given")

    if not os.path.isfile(args.src):
        sys.exit(f"ERROR: {args.src} not found")

    archived = None
    if not args.no_archive:
        archive_dir = args.archive_dir or os.path.join(repo_root(), ARCHIVE_DIR)
        # Never archive a file that already lives in the archive.
        if os.path.abspath(args.src).startswith(os.path.abspath(archive_dir) + os.sep):
            archived = args.src
        else:
            archived = archive_original(args.src, args.dst, archive_dir)

    before_kb = os.path.getsize(args.src) / 1024
    with Image.open(args.src) as im:
        im = im.convert("RGB")
        before = im.size
        out, used = fit(im, args.mode, args.allow_upscale)

    ext = os.path.splitext(args.dst)[1].lower()
    if ext in (".jpg", ".jpeg"):
        out.save(args.dst, quality=88, optimize=True, progressive=True)
    else:
        out.save(args.dst, optimize=True)

    if not args.quiet:
        after_kb = os.path.getsize(args.dst) / 1024
        line = (f"{before[0]}x{before[1]} {before_kb:.0f}KB "
                f"-> {out.size[0]}x{out.size[1]} {after_kb:.0f}KB  ({used})")
        if archived and os.path.abspath(archived) != os.path.abspath(args.src):
            line += f"  [original kept: {os.path.relpath(archived, repo_root())}]"
        print(line)


if __name__ == "__main__":
    main()
