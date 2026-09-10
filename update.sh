#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PAGES_BRANCH="${PAGES_BRANCH:-gh-pages}"
readonly GIT_REMOTE="${GIT_REMOTE:-origin}"

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: ./update.sh [--dry-run]" >&2
  exit 2
fi

command -v git >/dev/null 2>&1 || { echo "git is required." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required." >&2; exit 1; }

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/2048-pages.XXXXXXXX")"
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT INT TERM

site_dir="$tmp_dir/site"
remote_url="$(git -C "$SCRIPT_DIR" remote get-url "$GIT_REMOTE" 2>/dev/null || true)"
cname=""

if [[ "$dry_run" == true ]]; then
  mkdir -p -- "$site_dir"
else
  if [[ -z "$remote_url" ]]; then
    echo "Git remote '$GIT_REMOTE' is not configured." >&2
    exit 1
  fi

  echo "Preparing $PAGES_BRANCH in a temporary directory..."
  if git -C "$SCRIPT_DIR" ls-remote --exit-code --heads "$GIT_REMOTE" "$PAGES_BRANCH" >/dev/null 2>&1; then
    git clone --quiet --depth 1 --branch "$PAGES_BRANCH" --single-branch "$remote_url" "$site_dir"
    if [[ -f "$site_dir/CNAME" ]]; then
      cname="$(<"$site_dir/CNAME")"
    fi
  else
    git clone --quiet --no-checkout "$remote_url" "$site_dir"
    git -C "$site_dir" switch --quiet --orphan "$PAGES_BRANCH"
  fi

  # The path is always a fresh directory created below mktemp above.
  find "$site_dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
fi

repo_url="$remote_url"
if [[ "$repo_url" =~ ^git@github\.com:(.+)\.git$ ]]; then
  repo_url="https://github.com/${BASH_REMATCH[1]}"
elif [[ "$repo_url" =~ ^https://github\.com/(.+)\.git$ ]]; then
  repo_url="https://github.com/${BASH_REMATCH[1]}"
elif [[ ! "$repo_url" =~ ^https?:// ]]; then
  repo_url=""
fi

python3 - "$SCRIPT_DIR" "$site_dir" "$repo_url" <<'PY'
from __future__ import annotations

import hashlib
import html
import os
import re
import shutil
import sys
from pathlib import Path
from urllib.parse import quote


source = Path(sys.argv[1]).resolve()
destination = Path(sys.argv[2]).resolve()
repository_url = sys.argv[3]

if (source / "index.html").exists():
    raise SystemExit(
        "The repository-root index.html is reserved for the generated showcase. "
        "Move each game, including its index.html, into its own directory."
    )

excluded_parts = {".git", "node_modules", ".venv", "venv", "__pycache__"}
excluded_names = {".DS_Store"}


def is_excluded(path: Path) -> bool:
    relative = path.relative_to(source)
    return (
        any(part in excluded_parts for part in relative.parts)
        or path.name in excluded_names
        or path.name == ".env"
        or path.name.startswith(".env.")
    )


indexes = sorted(
    path
    for path in source.rglob("index.html")
    if path.parent != source and not is_excluded(path)
)

if not indexes:
    raise SystemExit("No game index.html files were found below the repository root.")

# Copy each self-contained game directory. This preserves CSS, JS, images, and
# other assets placed next to that game's index.html without publishing the
# repository's unrelated root files.
game_directories = sorted({index.parent for index in indexes}, key=lambda p: len(p.parts))
for game_directory in game_directories:
    relative_directory = game_directory.relative_to(source)
    target_directory = destination / relative_directory

    def ignore(directory: str, names: list[str]) -> set[str]:
        directory_path = Path(directory)
        ignored: set[str] = set()
        for name in names:
            candidate = directory_path / name
            try:
                if is_excluded(candidate):
                    ignored.add(name)
            except ValueError:
                ignored.add(name)
        return ignored

    shutil.copytree(
        game_directory,
        target_directory,
        dirs_exist_ok=True,
        ignore=ignore,
        symlinks=False,
    )


def extract_title(index: Path) -> str:
    try:
        content = index.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return index.parent.name
    match = re.search(r"<title[^>]*>(.*?)</title>", content, re.IGNORECASE | re.DOTALL)
    if not match:
        return index.parent.name
    title = re.sub(r"\s+", " ", html.unescape(match.group(1))).strip()
    return title or index.parent.name


cards: list[str] = []
for number, index in enumerate(indexes, start=1):
    relative_index = index.relative_to(source).as_posix()
    encoded_path = quote(relative_index, safe="/")
    title = extract_title(index)
    edition = index.parent.relative_to(source).as_posix()
    digest = hashlib.sha256(relative_index.encode()).digest()
    hue = 185 + digest[0] % 125
    cards.append(
        f'''<article class="game-card" style="--card-hue:{hue}deg">
          <div class="preview" aria-hidden="true">
            <iframe src="{html.escape(encoded_path, quote=True)}" loading="lazy" tabindex="-1" title="{html.escape(title, quote=True)}のプレビュー"></iframe>
            <div class="preview-shade"></div>
          </div>
          <div class="card-copy">
            <div class="card-meta"><span>EDITION {number:02d}</span><span class="live-dot">PLAYABLE</span></div>
            <h2>{html.escape(title)}</h2>
            <p>{html.escape(edition)}</p>
            <span class="play-label">この2048で遊ぶ <span aria-hidden="true">↗</span></span>
          </div>
          <a class="card-link" href="{html.escape(encoded_path, quote=True)}" aria-label="{html.escape(title, quote=True)}で遊ぶ"></a>
        </article>'''
    )

repo_link = ""
if repository_url:
    repo_link = f'<a class="repo-link" href="{html.escape(repository_url, quote=True)}">GitHub <span aria-hidden="true">↗</span></a>'

page = '''<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#080a0f">
  <meta name="description" content="さまざまなAIエージェントが作った2048を、見比べてそのまま遊べるショーケース。">
  <title>2048 / AI EDITIONS</title>
  <style>
    :root {
      color-scheme: dark;
      --ink: #f5f2e9;
      --muted: #a5a49f;
      --line: rgba(255, 255, 255, .12);
      --panel: rgba(19, 21, 27, .76);
      font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body {
      margin: 0;
      min-width: 320px;
      min-height: 100vh;
      color: var(--ink);
      background:
        radial-gradient(circle at 84% 3%, rgba(236, 105, 54, .2), transparent 27rem),
        radial-gradient(circle at 9% 35%, rgba(58, 178, 190, .13), transparent 30rem),
        #080a0f;
    }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      pointer-events: none;
      opacity: .23;
      background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 140 140' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='.12'/%3E%3C/svg%3E");
    }
    a { color: inherit; }
    .shell { width: min(1180px, calc(100% - 40px)); margin: 0 auto; }
    .site-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      min-height: 76px;
      border-bottom: 1px solid var(--line);
    }
    .brand { display: flex; align-items: center; gap: 12px; font-weight: 850; letter-spacing: -.04em; }
    .brand-mark {
      display: grid;
      place-items: center;
      width: 32px;
      aspect-ratio: 1;
      border: 1px solid rgba(255, 255, 255, .28);
      border-radius: 8px;
      background: linear-gradient(145deg, #f0a33a, #ea5839);
      color: #130d09;
      font-size: 11px;
      box-shadow: 0 0 22px rgba(238, 101, 54, .22);
    }
    .repo-link { color: var(--muted); text-decoration: none; font-size: 13px; letter-spacing: .04em; }
    .repo-link:hover { color: var(--ink); }
    .hero { padding: clamp(68px, 10vw, 130px) 0 70px; }
    .eyebrow { margin: 0 0 22px; color: #f3a048; font: 700 12px/1 monospace; letter-spacing: .18em; }
    h1 { margin: 0; max-width: 940px; font-size: clamp(56px, 10vw, 132px); line-height: .84; letter-spacing: -.075em; }
    h1 em { color: transparent; -webkit-text-stroke: 1px rgba(245, 242, 233, .55); font-style: normal; }
    .hero-foot {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 32px;
      align-items: end;
      margin-top: 42px;
    }
    .intro { max-width: 590px; margin: 0; color: var(--muted); font-size: clamp(15px, 2vw, 18px); line-height: 1.85; }
    .count { color: var(--muted); font: 650 12px/1.5 monospace; letter-spacing: .12em; text-align: right; }
    .count strong { display: block; color: var(--ink); font: 800 36px/1 sans-serif; letter-spacing: -.05em; }
    .section-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 22px; }
    .section-head h2 { margin: 0; font-size: 13px; letter-spacing: .14em; }
    .section-head span { color: var(--muted); font: 11px monospace; }
    .games { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 22px; padding-bottom: 110px; }
    .game-card {
      position: relative;
      overflow: hidden;
      min-height: 490px;
      border: 1px solid var(--line);
      border-radius: 22px;
      background: var(--panel);
      box-shadow: 0 28px 70px rgba(0, 0, 0, .25);
      isolation: isolate;
      transition: transform .35s ease, border-color .35s ease, box-shadow .35s ease;
    }
    .game-card:hover {
      transform: translateY(-7px);
      border-color: hsla(var(--card-hue), 80%, 68%, .5);
      box-shadow: 0 32px 80px rgba(0, 0, 0, .42), 0 0 35px hsla(var(--card-hue), 70%, 50%, .1);
    }
    .preview { position: relative; height: 310px; overflow: hidden; background: #101218; }
    .preview iframe {
      width: 150%;
      height: 150%;
      border: 0;
      pointer-events: none;
      transform: scale(.667);
      transform-origin: top left;
      filter: saturate(.9);
    }
    .preview-shade {
      position: absolute;
      inset: 0;
      background: linear-gradient(to bottom, transparent 55%, rgba(12, 14, 19, .94));
    }
    .card-copy { position: relative; z-index: 1; padding: 2px 25px 26px; }
    .card-meta { display: flex; justify-content: space-between; color: var(--muted); font: 10px/1 monospace; letter-spacing: .12em; }
    .live-dot { color: hsl(var(--card-hue), 75%, 68%); }
    .live-dot::before { content: ""; display: inline-block; width: 6px; height: 6px; margin-right: 7px; border-radius: 50%; background: currentColor; box-shadow: 0 0 10px currentColor; }
    .card-copy h2 { margin: 16px 0 8px; font-size: clamp(24px, 3vw, 34px); line-height: 1.08; letter-spacing: -.04em; }
    .card-copy p { margin: 0; color: var(--muted); font: 11px/1.4 monospace; }
    .play-label { display: inline-flex; gap: 10px; margin-top: 25px; color: hsl(var(--card-hue), 75%, 72%); font-size: 13px; font-weight: 750; }
    .card-link { position: absolute; z-index: 4; inset: 0; border-radius: inherit; }
    .card-link:focus-visible { outline: 3px solid hsl(var(--card-hue), 78%, 67%); outline-offset: -4px; }
    footer { display: flex; justify-content: space-between; gap: 20px; padding: 30px 0 45px; border-top: 1px solid var(--line); color: var(--muted); font: 11px/1.5 monospace; letter-spacing: .08em; }
    @media (max-width: 760px) {
      .shell { width: min(100% - 24px, 580px); }
      .hero { padding-top: 58px; }
      .hero-foot { grid-template-columns: 1fr; }
      .count { text-align: left; }
      .games { grid-template-columns: 1fr; }
      .game-card { min-height: 450px; }
      .preview { height: 280px; }
    }
    @media (prefers-reduced-motion: reduce) {
      html { scroll-behavior: auto; }
      .game-card { transition: none; }
    }
  </style>
</head>
<body>
  <header class="site-header shell">
    <div class="brand"><span class="brand-mark">2²</span><span>2048 / LAB</span></div>
    __REPO_LINK__
  </header>
  <main class="shell">
    <section class="hero">
      <p class="eyebrow">MULTI-AGENT EXPERIMENT / 2026</p>
      <h1>ONE GAME.<br><em>MANY MINDS.</em></h1>
      <div class="hero-foot">
        <p class="intro">同じ「2048」というお題から、AIエージェントたちはどこまで違うゲームを作るのか。気になるエディションを選んで、そのままプレイできます。</p>
        <div class="count"><strong>__COUNT__</strong>PLAYABLE EDITIONS</div>
      </div>
    </section>
    <div class="section-head"><h2>CHOOSE YOUR EDITION</h2><span>CLICK TO LAUNCH</span></div>
    <section class="games" aria-label="2048ゲーム一覧">
      __CARDS__
    </section>
  </main>
  <footer class="shell"><span>2048 / AI EDITIONS</span><span>BUILT BY MANY MINDS</span></footer>
</body>
</html>
'''

page = page.replace("__REPO_LINK__", repo_link)
page = page.replace("__COUNT__", f"{len(indexes):02d}")
page = page.replace("__CARDS__", "\n".join(cards))

destination.mkdir(parents=True, exist_ok=True)
(destination / "index.html").write_text(page, encoding="utf-8")
(destination / ".nojekyll").touch()
print(f"Built showcase with {len(indexes)} game(s).")
PY

if [[ -n "$cname" ]]; then
  printf '%s\n' "$cname" > "$site_dir/CNAME"
fi

if [[ "$dry_run" == true ]]; then
  python3 - "$site_dir" <<'PY'
from pathlib import Path
import sys

site = Path(sys.argv[1])
assert (site / "index.html").is_file()
assert (site / ".nojekyll").is_file()
games = [path for path in site.rglob("index.html") if path.parent != site]
assert games, "No games were copied"
print(f"Dry run passed: {len(games)} game index file(s) are ready to publish.")
PY
  exit 0
fi

git -C "$site_dir" add --all
if git -C "$site_dir" diff --cached --quiet; then
  echo "$PAGES_BRANCH is already up to date."
  exit 0
fi

git_name="$(git -C "$SCRIPT_DIR" config user.name || true)"
git_email="$(git -C "$SCRIPT_DIR" config user.email || true)"
git_name="${git_name:-2048 Pages Bot}"
git_email="${git_email:-pages@localhost}"

git -C "$site_dir" \
  -c user.name="$git_name" \
  -c user.email="$git_email" \
  commit --quiet -m "Update 2048 showcase"
git -C "$site_dir" push --quiet origin "HEAD:$PAGES_BRANCH"

echo "Published ${PAGES_BRANCH} without changing the current branch or working tree."
