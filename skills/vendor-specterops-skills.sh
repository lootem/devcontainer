#!/usr/bin/env bash
#
# vendor-specterops-skills.sh — re-vendor SpecterOps' standalone skills into
# tracked skills/ from upstream github.com/SpecterOps/skills.
#
# Maintainer-only, manual: not shipped into generated projects. Renovate runs
# this helper when it advances the pinned upstream commit.

set -euo pipefail

SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/skills"

# renovate: datasource=git-refs depName=https://github.com/SpecterOps/skills
REF="e655f93ab694c446b76672efe6e71e62aac0b7b8"
REPO="SpecterOps/skills"

die() { echo "Error: $*" >&2; exit 1; }
info() { echo "[vendor-specterops-skills] $*"; }

usage() {
  cat <<EOF
Usage: $SELF_NAME [--ref <sha>] [--repo <owner/repo>]

Re-vendors every standalone skill directly under upstream skills/ from
$REPO@$REF (default). Complete skill directories are copied recursively,
including their references/, scripts/, assets/, agents/, and other support
files. Plugin-bundled skills under plugins/*/skills/ are not imported.

Only operates on this repository's tracked skills/. Generated-project copies
may drift until install.sh --skills is run again.

      --ref <sha>          Commit to vendor from (default: pinned $REF).
      --repo <owner/repo>  Upstream repo (default: $REPO).
  -h, --help               Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)     [ $# -ge 2 ] || die "--ref requires a value"; REF="$2"; shift 2 ;;
    --ref=*)   REF="${1#*=}"; shift ;;
    --repo)    [ $# -ge 2 ] || die "--repo requires a value"; REPO="$2"; shift 2 ;;
    --repo=*)  REPO="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unknown argument: $1 (see --help)" ;;
  esac
done

[ -d "$SKILLS_DIR" ] || die "No skills/ directory found at $SKILLS_DIR"

has_specterops_frontmatter() { # has_specterops_frontmatter <SKILL.md>
  awk '
    /^---[[:space:]]*$/ { fences++; if (fences == 2) exit; next }
    fences == 1 { print }
  ' "$1" | awk '
    /^metadata:[[:space:]]*$/ { in_meta=1; next }
    in_meta && /^[a-zA-Z]/ { in_meta=0 }
    in_meta && /^[[:space:]]+source:[[:space:]]*"?specterops"?[[:space:]]*$/ { found=1 }
    END { exit !found }
  '
}

stamp_skill_md() { # stamp_skill_md <SKILL.md>
  local file="$1" tmp fence_count
  tmp="$(mktemp)"
  fence_count="$(grep -cE '^---[[:space:]]*$' "$file" || true)"
  [ "$fence_count" -ge 2 ] || die "$file has no frontmatter fences — refusing to stamp."

  awk '
    BEGIN { fences = 0; in_meta = 0; meta_seen = 0 }
    /^---[[:space:]]*$/ {
      fences++
      if (fences == 2 && !meta_seen) {
        print "metadata:"
        print "  source: specterops"
        print "  category: standalone"
      }
      print
      next
    }
    fences == 1 && /^metadata:[[:space:]]*$/ {
      meta_seen = 1
      in_meta = 1
      print
      print "  source: specterops"
      print "  category: standalone"
      next
    }
    fences == 1 && in_meta && /^[[:space:]]+source:/ { next }
    fences == 1 && in_meta && /^[[:space:]]+category:/ { next }
    fences == 1 && in_meta && /^[a-zA-Z]/ { in_meta = 0 }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

TMP_CLONE="$(mktemp -d)"
trap 'rm -rf "$TMP_CLONE"' EXIT

info "Cloning $REPO@$REF (sparse: skills/) ..."
git clone --filter=blob:none --sparse "https://github.com/$REPO" "$TMP_CLONE" >/dev/null 2>&1 \
  || die "Failed to clone https://github.com/$REPO"
(
  cd "$TMP_CLONE"
  git sparse-checkout set skills >/dev/null 2>&1 \
    || die "Failed to set sparse-checkout"
  git checkout "$REF" >/dev/null 2>&1 \
    || die "Failed to checkout $REPO@$REF"
)

UPSTREAM_SKILLS="$TMP_CLONE/skills"
[ -d "$UPSTREAM_SKILLS" ] || die "Upstream $REPO@$REF has no skills/ directory"
[ -f "$TMP_CLONE/LICENSE" ] || die "Upstream $REPO@$REF has no root LICENSE"

STAGE="$TMP_CLONE/.vendor-stage"
mkdir -p "$STAGE"
NAMES=()
for d in "$UPSTREAM_SKILLS"/*/; do
  [ -d "$d" ] || continue
  [ -f "$d/SKILL.md" ] || continue
  name="$(basename "$d")"
  cp -R "$d" "$STAGE/$name"
  stamp_skill_md "$STAGE/$name/SKILL.md"
  NAMES+=("$name")
done
[ "${#NAMES[@]}" -gt 0 ] || die "Upstream $REPO@$REF has no standalone skills under skills/"

# Validate every destination before removing stale skills or replacing current
# ones. Existing directories may be replaced only when their frontmatter marks
# them as owned by this vendor.
for name in "${NAMES[@]}"; do
  dest="$SKILLS_DIR/$name"
  [ -e "$dest" ] || continue
  if [ ! -f "$dest/SKILL.md" ] || ! has_specterops_frontmatter "$dest/SKILL.md"; then
    die "Name collision: skills/$name already exists and is not owned by the SpecterOps vendor."
  fi
done

REMOVED=0
for d in "$SKILLS_DIR"/*/; do
  [ -d "$d" ] || continue
  skill_md="$d/SKILL.md"
  [ -f "$skill_md" ] || continue
  if has_specterops_frontmatter "$skill_md"; then
    name="$(basename "$d")"
    rm -rf "$d"
    REMOVED=$((REMOVED + 1))
    info "removed skills/$name (source: specterops)"
  fi
done

ADDED=0
for name in "${NAMES[@]}"; do
  cp -R "$STAGE/$name" "$SKILLS_DIR/$name"
  ADDED=$((ADDED + 1))
  info "added skills/$name (category: standalone)"
done
cp "$TMP_CLONE/LICENSE" "$SKILLS_DIR/SPECTEROPS-SKILLS-LICENSE"

echo
info "removed $REMOVED, added $ADDED standalone skills"
info "generated-project skill copies untouched — re-run install.sh --skills to refresh them"
