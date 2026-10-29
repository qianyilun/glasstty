#!/bin/sh
# Installs glasstty and turns it on in Ghostty.
#
#   curl -fsSL https://raw.githubusercontent.com/qianyilun/glasstty/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/qianyilun/glasstty/main/install.sh | sh -s -- --tmux
#
# Downloads the latest glasstty into ~/.config/ghostty/glasstty (replacing an earlier download
# there), then runs `glasstty enable` with the arguments given here. Your config files are
# backed up before they change. GLASSTTY_DIR picks another folder, GLASSTTY_REF another branch
# or tag, and GLASSTTY_SRC a local copy to install instead of downloading.
set -eu

repo=qianyilun/glasstty
ref=${GLASSTTY_REF:-main}
dest=${GLASSTTY_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/glasstty}

die() {
  printf 'glasstty install: %s\n' "$1" >&2
  exit 1
}

if [ -d "$dest/.git" ]; then
  # A git clone from the manual install: leave it to git and just enable it.
  if [ ! -f "$dest/bin/glasstty" ]; then
    die "the git clone in $dest predates this installer; run: git -C \"$dest\" pull, then run this again"
  fi
  printf 'Using the git clone in %s (update it with: git -C "%s" pull)\n' "$dest" "$dest"
  exec sh "$dest/bin/glasstty" enable "$@"
fi
if [ -e "$dest" ] && [ ! -f "$dest/glasstty.ghostty" ]; then
  die "$dest exists and is not a glasstty folder; set GLASSTTY_DIR to install somewhere else"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

if [ -n "${GLASSTTY_SRC:-}" ]; then
  mkdir "$tmp/glasstty"
  (cd "$GLASSTTY_SRC" && tar -cf - --exclude .git .) | (cd "$tmp/glasstty" && tar -xf -)
else
  case $ref in
    v[0-9]*) url="https://github.com/$repo/archive/refs/tags/$ref.tar.gz" ;;
    *) url="https://github.com/$repo/archive/refs/heads/$ref.tar.gz" ;;
  esac
  printf 'Downloading %s\n' "$url"
  curl -fsSL "$url" | tar -xzf - -C "$tmp" || die "download failed"
fi

src=
for dir in "$tmp"/*/; do
  src=${dir%/}
done
[ -n "$src" ] && [ -f "$src/glasstty.ghostty" ] || die "the download does not look like glasstty"

mkdir -p "$(dirname "$dest")"
rm -rf "$dest"
mv "$src" "$dest"
chmod +x "$dest/bin/glasstty"
printf 'Installed glasstty in %s\n\n' "$dest"

"$dest/bin/glasstty" enable "$@"
printf '\nTo turn it off later:  %s/bin/glasstty disable\n' "$dest"
