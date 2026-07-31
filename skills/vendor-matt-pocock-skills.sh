#!/usr/bin/env bash
#
# vendor-matt-pocock-skills.sh — re-vendor Matt Pocock's skills into tracked
# skills/ from upstream github.com/mattpocock/skills.
#
# Maintainer-only, manual: not wired into install.sh or any CI/lifecycle hook.
# This helper itself is excluded from the `install.sh --skills` copy (see
# install.sh) since it operates on THIS repo's tracked skills/, not on a
# generated project's .claude/skills/.
#
# Every skills/<name>/SKILL.md tagged `author: mattpocock` (nested under
# `metadata:`) is deleted, directory-wide, then upstream's skills/engineering/
# and skills/productivity/ are cloned at a pinned commit, flattened into
# skills/<name>/, and re-stamped with `metadata: author: mattpocock` +
# `category: <engineering|productivity>`.
#
# The default --ref is pinned to the exact commit these skills were last
# vendored from — NOT upstream's latest — because upstream renamed/merged
# skills on 2026-07-02 (to-prd -> to-spec, to-issues merged into to-tickets).
# Bumping --ref is a deliberate, reviewed decision, not a routine update.
#
#   skills/vendor-matt-pocock-skills.sh
#   skills/vendor-matt-pocock-skills.sh --ref <sha>
#   skills/vendor-matt-pocock-skills.sh --repo <owner/repo>

set -euo pipefail

SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/skills"

# renovate: datasource=git-refs depName=https://github.com/mattpocock/skills
REF="e9fcdf95b402d360f90f1db8d776d5dd450f9234"
REPO="mattpocock/skills"

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "[vendor-matt-pocock-skills] $*"; }

usage() {
  cat <<EOF
Usage: $SELF_NAME [--ref <sha>] [--repo <owner/repo>]

Re-vendors Matt Pocock's skills into tracked skills/ from upstream
$REPO@$REF (default). Removes every skills/<name>/ whose SKILL.md carries a
nested "metadata: author: mattpocock", then clones upstream's
skills/engineering/ + skills/productivity/ at the pinned ref, flattens them
into skills/<name>/, and stamps each cloned SKILL.md with
"metadata: author: mattpocock" + "category: <engineering|productivity>".

Only operates on tracked skills/ — .claude/skills/ (the local installed
copy, gitignored) is left alone and may drift until you next run
"install.sh --skills".

      --ref <sha>          Commit to vendor from (default: pinned $REF).
                            Bumping this is a deliberate decision — upstream
                            has renamed/merged skills before.
      --repo <owner/repo>  Upstream repo (default: $REPO).
  -h, --help               Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)     REF="$2"; shift 2 ;;
    --ref=*)   REF="${1#*=}"; shift ;;
    --repo)    REPO="$2"; shift 2 ;;
    --repo=*)  REPO="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unknown argument: $1 (see --help)" ;;
  esac
done

[ -d "$SKILLS_DIR" ] || die "No skills/ directory found at $SKILLS_DIR"

# --- Remove: delete every skills/<name>/ whose SKILL.md carries a nested ----
# `metadata: author: mattpocock` — parsed from the fenced frontmatter block
# only, so a stray body mention can never trigger a deletion.
has_mattpocock_frontmatter() { # has_mattpocock_frontmatter <SKILL.md>
  awk '
    /^---[[:space:]]*$/ { fences++; if (fences == 2) exit; next }
    fences == 1 { print }
  ' "$1" | awk '
    /^metadata:[[:space:]]*$/ { in_meta=1; next }
    in_meta && /^[a-zA-Z]/ { in_meta=0 }
    in_meta && /^[[:space:]]+author:[[:space:]]*mattpocock[[:space:]]*$/ { found=1 }
    END { exit !found }
  '
}

REMOVED=0
for d in "$SKILLS_DIR"/*/; do
  name="$(basename "$d")"
  skill_md="$d/SKILL.md"
  [ -f "$skill_md" ] || continue
  if has_mattpocock_frontmatter "$skill_md"; then
    rm -rf "$d"
    REMOVED=$((REMOVED + 1))
    info "removed skills/$name (author: mattpocock)"
  fi
done

# --- Clone: partial + sparse checkout, pinned to $REF -----------------------
TMP_CLONE="$(mktemp -d)"
trap 'rm -rf "$TMP_CLONE"' EXIT

info "Cloning $REPO@$REF (sparse: skills/engineering, skills/productivity) ..."
git clone --filter=blob:none --sparse "https://github.com/$REPO" "$TMP_CLONE" >/dev/null 2>&1 \
  || die "Failed to clone https://github.com/$REPO"
(
  cd "$TMP_CLONE"
  git sparse-checkout set skills/engineering skills/productivity >/dev/null 2>&1 \
    || die "Failed to set sparse-checkout"
  git checkout "$REF" >/dev/null 2>&1 \
    || die "Failed to checkout $REPO@$REF"
)

# --- Flatten + collision check -----------------------------------------------
# name -> category ("engineering" or "productivity"); a name present in both
# is a hard error, not a silent pick. Unlike install.sh/update.sh, this script
# is maintainer-only (never shipped into a generated project or copied to
# .claude/skills/), so it isn't held to their bash-3.2/macOS portability
# constraint — a bash-4+ associative array is fine here.
declare -A NAME_CATEGORY

for category in engineering productivity; do
  cat_dir="$TMP_CLONE/skills/$category"
  [ -d "$cat_dir" ] || continue
  for d in "$cat_dir"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [ -n "${NAME_CATEGORY[$name]:-}" ]; then
      die "Name collision: '$name' exists in both skills/engineering/ and skills/productivity/ upstream — refusing to guess which one wins."
    fi
    NAME_CATEGORY[$name]="$category"
  done
done

# --- Stamp: ensure a nested metadata: block on each cloned SKILL.md ----------
# with author/category set (overwrite-if-present, idempotent). Uses awk/sed
# only — no yq dependency (see update.sh precedent for the same constraint).
stamp_skill_md() { # stamp_skill_md <SKILL.md> <category>
  local file="$1" category="$2" tmp
  tmp="$(mktemp)"

  local fence_count
  fence_count="$(grep -cE '^---[[:space:]]*$' "$file" || true)"
  [ "$fence_count" -ge 2 ] || die "$file has no frontmatter fences — refusing to stamp."

  awk -v author="mattpocock" -v category="$category" '
    BEGIN { fences = 0; in_meta = 0; meta_seen = 0 }
    /^---[[:space:]]*$/ {
      fences++
      if (fences == 2 && !meta_seen) {
        print "metadata:"
        print "  author: " author
        print "  category: " category
      }
      print
      next
    }
    fences == 1 && /^metadata:[[:space:]]*$/ {
      meta_seen = 1
      in_meta = 1
      print
      print "  author: " author
      print "  category: " category
      next
    }
    fences == 1 && in_meta && /^[[:space:]]+author:/ { next }
    fences == 1 && in_meta && /^[[:space:]]+category:/ { next }
    fences == 1 && in_meta && /^[a-zA-Z]/ { in_meta = 0 }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# --- Copy each name into skills/<name>/, then stamp its SKILL.md ------------
ADDED_ENGINEERING=0
ADDED_PRODUCTIVITY=0
for name in $(printf '%s\n' "${!NAME_CATEGORY[@]}" | sort); do
  category="${NAME_CATEGORY[$name]}"
  src="$TMP_CLONE/skills/$category/$name"
  dest="$SKILLS_DIR/$name"
  rm -rf "$dest"
  cp -R "$src" "$dest"
  [ -f "$dest/SKILL.md" ] || die "$dest/SKILL.md missing after copy from upstream $category/$name"
  stamp_skill_md "$dest/SKILL.md" "$category"
  info "added skills/$name (category: $category)"
  if [ "$category" = "engineering" ]; then
    ADDED_ENGINEERING=$((ADDED_ENGINEERING + 1))
  else
    ADDED_PRODUCTIVITY=$((ADDED_PRODUCTIVITY + 1))
  fi
done

echo
info "removed $REMOVED, added $((ADDED_ENGINEERING + ADDED_PRODUCTIVITY)) (engineering: $ADDED_ENGINEERING, productivity: $ADDED_PRODUCTIVITY), 0 collisions"
info ".claude/skills/ (local installed copy) untouched — re-run install.sh --skills to refresh it"
