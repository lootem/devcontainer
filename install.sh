#!/usr/bin/env bash
#
# install.sh — scaffold a new project with lootem's devcontainer + editor config.
#
# Designed to be run as a one-liner:
#   curl -fsSL https://ltm.sh/dev | bash -s -- --language python,go
#
# It clones github.com/lootem/devcontainer, takes .devcontainer/ as a baseline,
# and extends it with the files under templates/<language>/ for each language
# you select. Prompts (language, overwrite, dependency install) read from
# /dev/tty so they work even when the script is piped into bash.

set -euo pipefail

GENERATOR_VERSION="1"

run_update_mode() {

REF="main"
REPO="lootem/devcontainer"
REF_SET=false
REPO_SET=false
FULL=false
UPDATE_ACK_DRIFT=false
REPLACE_LANGS=false
REPLACE_TOOLS=false
REPLACE_CLIS=false
REPLACE_SKILLS=false
REPLACE_EXTENSIONS=false
NEW_SKILLS=""
NEW_EXTENSIONS=""
EXTRA_ARGS=()

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "[update] $*"; }

usage() {
  cat <<EOF
Usage: install.sh update [--full] [--repo <owner/repo>] [--ref <ref>] [-- <extra install.sh args>]

Default (surgical): fetches upstream's .devcontainer/Dockerfile +
devcontainer.json (parse-only) and bumps in place every pinned version this
repo already tracks — Renovate-annotated ARGs, the base image @sha256: digest,
devcontainer.json extension @version pins, and signing keys/fingerprints
(awscli.pub, MS_KEY_FP*, inline EXPECTED= fingerprints) — for keys present
both locally and upstream. Everything else (toggle ARGs, comments, local
edits) is left alone. Prints a summary of what bumped and what was skipped.

      --full        Re-run install.sh and overwrite .devcontainer/ wholesale
      --no-language  Full update: remove all language selections
      --no-tool      Full update: remove all tool selections
      --no-cli       Full update: remove all CLI selections; state is retained
      --no-skills    Full update: disable skills copying
      --no-extensions Full update: disable recommended extensions
                     (today's behavior) instead of the surgical transplant.
                     Only path to structural upstream changes.
      --repo <o/r>  Source repo for pins/install.sh (default: $REPO)
      --ref <ref>   Branch/tag/commit to pull (default: $REF)
  -h, --help        Show this help

Anything after a lone "--" is forwarded verbatim to install.sh; only used
with --full (e.g. "--full -- --force" to overwrite files without prompting).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --full)    FULL=true; shift ;;
    --force|-f) UPDATE_ACK_DRIFT=true; EXTRA_ARGS+=(--force); shift ;;
    --repo)    REPO="$2"; REPO_SET=true; shift 2 ;;
    --repo=*)  REPO="${1#*=}"; REPO_SET=true; shift ;;
    --ref)     REF="$2"; REF_SET=true; shift 2 ;;
    --ref=*)   REF="${1#*=}"; REF_SET=true; shift ;;
    --language) REPLACE_LANGS=true; EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
    --tool) REPLACE_TOOLS=true; EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
    --cli) REPLACE_CLIS=true; EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
    --language=*) REPLACE_LANGS=true; EXTRA_ARGS+=("$1"); shift ;;
    --tool=*) REPLACE_TOOLS=true; EXTRA_ARGS+=("$1"); shift ;;
    --cli=*) REPLACE_CLIS=true; EXTRA_ARGS+=("$1"); shift ;;
    --no-language) REPLACE_LANGS=true; EXTRA_ARGS+=(--base-only); shift ;;
    --no-tool) REPLACE_TOOLS=true; shift ;;
    --no-cli) REPLACE_CLIS=true; shift ;;
    --skills) REPLACE_SKILLS=true; NEW_SKILLS=true; shift ;;
    --no-skills) REPLACE_SKILLS=true; NEW_SKILLS=false; shift ;;
    --extensions) REPLACE_EXTENSIONS=true; NEW_EXTENSIONS=true; shift ;;
    --no-extensions) REPLACE_EXTENSIONS=true; NEW_EXTENSIONS=false; shift ;;
    --)        shift; EXTRA_ARGS+=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unknown argument: $1 (see --help)" ;;
  esac
done

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SELF_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$REPO_ROOT/.devcontainer/Dockerfile"
DEVCONTAINER_JSON="$REPO_ROOT/.devcontainer/devcontainer.json"
SCAFFOLD_DEST="$REPO_ROOT/.devcontainer/scaffold.json"
SCAFFOLD_JSON="$SCAFFOLD_DEST"

[ -f "$SCAFFOLD_JSON" ] || die "No .devcontainer/scaffold.json found; this project predates unified updates. Run a full install explicitly."
if [ "$(jq -r '.schemaVersion // empty' "$SCAFFOLD_JSON")" = "0" ]; then
  MIGRATED_SCAFFOLD="$(mktemp)"
  jq '.schemaVersion = 1 | .generatorVersion = (.generatorVersion // "0")' "$SCAFFOLD_JSON" > "$MIGRATED_SCAFFOLD"
  SCAFFOLD_JSON="$MIGRATED_SCAFFOLD"
  info "Scaffold metadata migration candidate: schemaVersion 0 -> 1; generatorVersion absent -> 0."
fi
jq -e '.schemaVersion == 1 and (.sourceRepository | type == "string") and (.trackingRef | type == "string") and (.resolvedCommit | type == "string") and (.languages | type == "array") and (.tools | type == "array") and (.clis | type == "array") and (.skills | type == "boolean") and (.extensions | type == "boolean")' "$SCAFFOLD_JSON" >/dev/null || die "Unsupported or invalid scaffold metadata; a full update or explicit migration is required."
[ "$REPO_SET" = true ] || REPO="$(jq -r .sourceRepository "$SCAFFOLD_JSON")"
[ "$REF_SET" = true ] || REF="$(jq -r .trackingRef "$SCAFFOLD_JSON")"

[ -f "$DOCKERFILE" ] \
  || die "No .devcontainer/Dockerfile found at $DOCKERFILE — run this from a repo generated by install.sh."

# ─────────────────────────────────────────────────────────────────────────────
# Surgical mode (default)
# ─────────────────────────────────────────────────────────────────────────────

# Fetch a single upstream file (path relative to the repo root), parse-only
# (never executed). Kept as its own function/line-pair so tests can swap it
# for a local `cp`.
fetch_upstream() { # fetch_upstream <repo-relative-path> <dest>
  if [ -n "${INSTALL_SH_LOCAL_SOURCE:-}" ]; then cp "$INSTALL_SH_LOCAL_SOURCE/$1" "$2" || die "Missing local upstream $1"; return; fi
  curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/$1" -o "$2" \
    || die "Failed to fetch upstream $1 from https://raw.githubusercontent.com/$REPO/$REF/$1"
}

# Same, but a missing upstream file (e.g. a language with no extensions.json)
# is a non-fatal "not found" rather than a die() — never fail per the surgical
# transplant's "skip, don't error" contract.
fetch_upstream_optional() { # fetch_upstream_optional <repo-relative-path> <dest> -> 0 fetched, 1 not found
  if [ -n "${INSTALL_SH_LOCAL_SOURCE:-}" ]; then [ -f "$INSTALL_SH_LOCAL_SOURCE/$1" ] || return 1; cp "$INSTALL_SH_LOCAL_SOURCE/$1" "$2"; return; fi
  if curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/$1" -o "$2" 2>/dev/null; then
    return 0
  fi
  rm -f "$2"
  return 1
}

# ARG names annotated by a `# renovate:` comment on the line directly above —
# i.e. the ones Renovate (or a dedicated workflow, for the base digest) tracks.
# NB: no `grep -P` — BSD grep on macOS lacks PCRE support.
renovate_arg_names() { # renovate_arg_names <dockerfile> -> ARG names, one per line
  awk '/^# renovate:/ { f=1; next } f { print; f=0 }' "$1" \
    | sed -n -E 's/^ARG ([A-Z_]+)=.*$/\1/p'
}

arg_value() { # arg_value <dockerfile> <name> -> current value (empty if absent)
  sed -n -E "s/^ARG $2=(.*)\$/\1/p" "$1" | head -1
}

# Replace, in $1 (mutated in place), the value of every renovate-tracked ARG
# whose name also appears upstream. Anchored on the preceding `# renovate:`
# comment (not on `ARG ...=` in general) so a toggle ARG can never be touched,
# even if its name happened to collide.
transplant_dockerfile_pins() { # transplant_dockerfile_pins <local> <upstream>
  local local_df="$1" upstream_df="$2" tmp
  tmp="$(mktemp)"
  cp "$local_df" "$tmp"

  local local_keys upstream_keys key lval uval
  local_keys="$(renovate_arg_names "$local_df")"
  upstream_keys="$(renovate_arg_names "$upstream_df")"

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if ! printf '%s\n' "$upstream_keys" | grep -qxF "$key"; then
      SKIPPED_LOCAL_ONLY+=("ARG $key")
      continue
    fi
    lval="$(arg_value "$tmp" "$key")"
    uval="$(arg_value "$upstream_df" "$key")"
    [ -z "$uval" ] && continue
    [ "$lval" = "$uval" ] && continue
    awk -v name="$key" -v newval="$uval" '
      /^# renovate:/ {
        print
        if ((getline nxt) > 0) {
          if (nxt ~ ("^ARG " name "=")) { print "ARG " name "=" newval } else { print nxt }
        }
        next
      }
      { print }
    ' "$tmp" > "$tmp.new"
    mv "$tmp.new" "$tmp"
    BUMPED+=("ARG $key: $lval -> $uval")
  done <<< "$local_keys"

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    printf '%s\n' "$local_keys" | grep -qxF "$key" || SKIPPED_UPSTREAM_ONLY+=("ARG $key")
  done <<< "$upstream_keys"

  mv "$tmp" "$local_df"
}

# The base image digest isn't `# renovate:`-annotated (a separate workflow
# tracks it, since the docker datasource can't date a rolling tag) — handle it
# as its own single-line transplant, matched by image name.
transplant_base_digest() { # transplant_base_digest <local> <upstream>
  local local_df="$1" upstream_df="$2"
  local limage ldigest uimage udigest
  limage="$(sed -n -E 's/^FROM ([^@[:space:]]+)@sha256:[0-9a-f]+.*$/\1/p' "$local_df" | head -1)"
  ldigest="$(sed -n -E 's/^FROM [^@[:space:]]+@(sha256:[0-9a-f]+).*$/\1/p' "$local_df" | head -1)"
  uimage="$(sed -n -E 's/^FROM ([^@[:space:]]+)@sha256:[0-9a-f]+.*$/\1/p' "$upstream_df" | head -1)"
  udigest="$(sed -n -E 's/^FROM [^@[:space:]]+@(sha256:[0-9a-f]+).*$/\1/p' "$upstream_df" | head -1)"

  if [ -z "$ldigest" ] || [ -z "$udigest" ] || [ "$limage" != "$uimage" ]; then
    SKIPPED_LOCAL_ONLY+=("base image digest (no matching FROM upstream)")
    return
  fi
  [ "$ldigest" = "$udigest" ] && return

  # Scoped to the FROM line only (not a file-wide replace) — a digest string
  # is effectively unique, but there's no reason to risk a stray match.
  awk -v old="@${ldigest}" -v new="@${udigest}" '
    /^FROM / { sub(old, new) }
    { print }
  ' "$local_df" > "$local_df.tmp" && mv "$local_df.tmp" "$local_df"
  BUMPED+=("base image digest: $ldigest -> $udigest")
}

# Byte-for-byte replace $1 (mutated in place) with $2 if they differ. Used for
# security-critical files (awscli.pub) that aren't line-oriented pins — the
# upstream copy is only ever fetched parse-only (never imported/executed) by
# this script; the Dockerfile's own gpg fingerprint check is the real gate.
transplant_file_verbatim() { # transplant_file_verbatim <local> <upstream> <label>
  local local_file="$1" upstream_file="$2" label="$3"
  if [ ! -f "$upstream_file" ]; then
    [ -f "$local_file" ] && SKIPPED_LOCAL_ONLY+=("$label (no matching upstream file)")
    return
  fi
  if [ ! -f "$local_file" ]; then
    SKIPPED_UPSTREAM_ONLY+=("$label")
    return
  fi
  if cmp -s "$local_file" "$upstream_file"; then
    return
  fi
  cp "$upstream_file" "$local_file"
  BUMPED+=("$label (replaced with upstream)")
}

# Like transplant_dockerfile_pins, but for an ARG with no `# renovate:` anchor
# (e.g. MS_KEY_FP*) — matched directly on `^ARG NAME=`. Do NOT add a
# `# renovate:` comment to such an ARG just to reuse the other helper: Renovate
# would then try to "update" a fingerprint it has no datasource for.
transplant_named_arg() { # transplant_named_arg <local_df> <upstream_df> <ARG_NAME>
  local local_df="$1" upstream_df="$2" name="$3" lval uval
  lval="$(arg_value "$local_df" "$name")"
  uval="$(arg_value "$upstream_df" "$name")"
  if [ -z "$uval" ]; then
    [ -n "$lval" ] && SKIPPED_LOCAL_ONLY+=("ARG $name")
    return
  fi
  if [ -z "$lval" ]; then
    SKIPPED_UPSTREAM_ONLY+=("ARG $name")
    return
  fi
  [ "$lval" = "$uval" ] && return
  awk -v name="$name" -v newval="$uval" '
    $0 ~ ("^ARG " name "=") { print "ARG " name "=" newval; next }
    { print }
  ' "$local_df" > "$local_df.tmp" && mv "$local_df.tmp" "$local_df"
  BUMPED+=("ARG $name: $lval -> $uval")
}

# Find the line number of the `EXPECTED="..."` line inside the RUN block that
# references <anchor> (a unique nearby token, e.g. "claude-code.asc" or
# "awscli.pub") — a RUN instruction is a `^RUN ` line plus every following
# line ending in a line-continuation backslash. Scoping to the block (rather
# than a bare EXPECTED= match) is what keeps the claude-code and awscli
# fingerprints from cross-contaminating when both live in the same Dockerfile.
expected_line_no() { # expected_line_no <dockerfile> <anchor> -> line number, or empty if not found
  awk -v anchor="$2" '
    /^RUN / { in_block=1; has_anchor=0; exp_line=0 }
    in_block {
      if (index($0, anchor) > 0) has_anchor=1
      if ($0 ~ /^[[:space:]]*EXPECTED="/) exp_line=NR
      if ($0 !~ /\\$/) {
        if (has_anchor && exp_line) { print exp_line; exit }
        in_block=0
      }
    }
  ' "$1"
}

expected_value() { # expected_value <dockerfile> <line-no> -> value at that line (empty if absent)
  [ -z "$2" ] && return
  sed -n "${2}p" "$1" | sed -n -E 's/^[[:space:]]*EXPECTED="([^"]*)".*$/\1/p'
}

# Transplant the inline `EXPECTED="…"` fingerprint scoped to the RUN block
# that references <anchor>, for the given upstream/local Dockerfiles.
transplant_expected() { # transplant_expected <local_df> <upstream_df> <anchor> <label>
  local local_df="$1" upstream_df="$2" anchor="$3" label="$4"
  local lline uline lval uval
  lline="$(expected_line_no "$local_df" "$anchor")"
  uline="$(expected_line_no "$upstream_df" "$anchor")"
  lval="$(expected_value "$local_df" "$lline")"
  uval="$(expected_value "$upstream_df" "$uline")"
  if [ -z "$uval" ]; then
    [ -n "$lval" ] && SKIPPED_LOCAL_ONLY+=("EXPECTED ($label)")
    return
  fi
  if [ -z "$lval" ]; then
    SKIPPED_UPSTREAM_ONLY+=("EXPECTED ($label)")
    return
  fi
  [ "$lval" = "$uval" ] && return
  awk -v n="$lline" -v newval="$uval" '
    NR == n { sub(/EXPECTED="[^"]*"/, "EXPECTED=\"" newval "\"") }
    { print }
  ' "$local_df" > "$local_df.tmp" && mv "$local_df.tmp" "$local_df"
  BUMPED+=("EXPECTED ($label): $lval -> $uval")
}

# All upstream "publisher.name@version" extension pins this repo could ever
# carry: the base devcontainer.json's pins, plus each *currently enabled*
# language's templates/<lang>/extensions.json — install.sh merges the latter
# into the generated devcontainer.json too, so the base file alone isn't the
# full picture (a language-specific pin would otherwise always look
# local-only, since upstream's base devcontainer.json never carries it).
collect_upstream_extension_pins() { # collect_upstream_extension_pins <upstream-devcontainer.json> <enabled-lang-tokens, newline-list>
  local upstream_json="$1" langs="$2" lang tmp_ext
  [ -f "$upstream_json" ] && jq -r '(.customizations.vscode.extensions // [])[] | select(test("@"))' "$upstream_json" 2>/dev/null
  while IFS= read -r lang; do
    [ -z "$lang" ] && continue
    tmp_ext="$(mktemp)"
    if fetch_upstream_optional "templates/$lang/extensions.json" "$tmp_ext"; then
      jq -r '.[] | select(test("@"))' "$tmp_ext" 2>/dev/null
    fi
    rm -f "$tmp_ext"
  done <<< "$langs"
}

# devcontainer.json extension pins ("publisher.name@x.y.z"), matched by
# extension id (the part before the last "@").
transplant_devcontainer_json_pins() { # transplant_devcontainer_json_pins <local> <upstream-extension-pins, newline-list>
  local local_json="$1" upstream_exts="$2"
  if ! command -v jq >/dev/null 2>&1; then
    info "jq not found — skipping devcontainer.json extension pin transplant"
    return
  fi
  [ -f "$local_json" ] || return

  local local_exts ext id uext uver lver
  local_exts="$(jq -r '(.customizations.vscode.extensions // [])[] | select(test("@"))' "$local_json" 2>/dev/null || true)"

  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    id="${ext%@*}"
    lver="${ext##*@}"
    uext="$(printf '%s\n' "$upstream_exts" | grep -F "${id}@" || true)"
    if [ -z "$uext" ]; then
      SKIPPED_LOCAL_ONLY+=("devcontainer.json extension $id")
      continue
    fi
    uver="${uext##*@}"
    [ "$lver" = "$uver" ] && continue
    jq --arg old "$ext" --arg new "$uext" \
      '(.customizations.vscode.extensions // []) |= map(if . == $old then $new else . end)' \
      "$local_json" > "$local_json.tmp" && mv "$local_json.tmp" "$local_json"
    BUMPED+=("devcontainer.json $id: $lver -> $uver")
  done <<< "$local_exts"

  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    id="${ext%@*}"
    printf '%s\n' "$local_exts" | grep -qF "${id}@" || SKIPPED_UPSTREAM_ONLY+=("devcontainer.json extension $id")
  done <<< "$upstream_exts"
}

# --language tokens (python/go/js/dotnet) currently enabled in the local
# Dockerfile — the only ones with a templates/<lang>/extensions.json; --tool
# ARGs have no extensions of their own. Uses arg_token() (defined below).
detect_enabled_langs() { # detect_enabled_langs <dockerfile> -> tokens, one per line
  local arg_name token
  while IFS= read -r arg_name; do
    [ -z "$arg_name" ] && continue
    token="$(arg_token "$arg_name")" || continue
    case "$arg_name" in
      PYTHON|GOLANG|NODEJS|DOTNET) echo "$token" ;;
    esac
  done < <(sed -n -E 's/^ARG ([A-Z_]+)=true[[:space:]]*$/\1/p' "$1")
}

run_surgical() {
  info "Surgical mode: transplanting pinned versions from $REPO@$REF (parse-only, never executed)"

  local up_dockerfile up_devcontainer up_awscli_pub up_dependencies_lock up_installer resolved_commit upstream_generator
  up_dockerfile="$(mktemp)"
  up_devcontainer="$(mktemp)"
  up_awscli_pub="$(mktemp)"
  up_dependencies_lock="$(mktemp)"
  up_installer="$(mktemp)"

  fetch_upstream ".devcontainer/Dockerfile" "$up_dockerfile"
  fetch_upstream ".devcontainer/devcontainer.json" "$up_devcontainer"
  fetch_upstream_optional ".devcontainer/awscli.pub" "$up_awscli_pub" || true
  fetch_upstream_optional ".devcontainer/dependencies.lock.json" "$up_dependencies_lock" || true
  fetch_upstream "install.sh" "$up_installer"
  bash -n "$up_installer" || die "Upstream install.sh failed validation."
  if [ -s "$up_dependencies_lock" ]; then jq -e '.schemaVersion == 1' "$up_dependencies_lock" >/dev/null 2>&1 || die "Upstream dependency lock failed validation."; fi
  jq -e 'type == "object"' "$up_devcontainer" >/dev/null || die "Upstream devcontainer.json failed validation."
  local stage candidate_dockerfile candidate_devcontainer candidate_aws candidate_lock candidate_scaffold backup
  stage="$(mktemp -d)"
  candidate_dockerfile="$stage/Dockerfile"; cp "$DOCKERFILE" "$candidate_dockerfile"
  candidate_devcontainer="$stage/devcontainer.json"; cp "$DEVCONTAINER_JSON" "$candidate_devcontainer"
  candidate_aws="$stage/awscli.pub"; [ ! -f "$REPO_ROOT/.devcontainer/awscli.pub" ] || cp "$REPO_ROOT/.devcontainer/awscli.pub" "$candidate_aws"
  candidate_lock="$stage/dependencies.lock.json"; [ ! -f "$REPO_ROOT/.devcontainer/dependencies.lock.json" ] || cp "$REPO_ROOT/.devcontainer/dependencies.lock.json" "$candidate_lock"
  candidate_scaffold="$stage/scaffold.json"

  local enabled_langs upstream_ext_pins
  enabled_langs="$(detect_enabled_langs "$DOCKERFILE")"
  upstream_ext_pins="$(collect_upstream_extension_pins "$up_devcontainer" "$enabled_langs")"

  BUMPED=()
  SKIPPED_UPSTREAM_ONLY=()
  SKIPPED_LOCAL_ONLY=()

  transplant_dockerfile_pins "$candidate_dockerfile" "$up_dockerfile"
  transplant_base_digest "$candidate_dockerfile" "$up_dockerfile"
  transplant_devcontainer_json_pins "$candidate_devcontainer" "$upstream_ext_pins"
  transplant_named_arg "$candidate_dockerfile" "$up_dockerfile" "MS_KEY_FP"
  transplant_named_arg "$candidate_dockerfile" "$up_dockerfile" "MS_KEY_FP_2025"
  transplant_expected "$candidate_dockerfile" "$up_dockerfile" "claude-code.asc" "claude-code"
  transplant_expected "$candidate_dockerfile" "$up_dockerfile" "awscli.pub" "awscli"
  transplant_file_verbatim "$candidate_aws" "$up_awscli_pub" "awscli.pub"
  transplant_file_verbatim "$candidate_lock" \
    "$up_dependencies_lock" "dependencies.lock.json"

  if [ -n "${INSTALL_SH_LOCAL_SOURCE:-}" ] && git -C "$INSTALL_SH_LOCAL_SOURCE" rev-parse HEAD >/dev/null 2>&1; then
    resolved_commit="$(git -C "$INSTALL_SH_LOCAL_SOURCE" rev-parse HEAD)"
  elif printf '%s' "$REF" | grep -Eq '^[0-9a-f]{40}$'; then
    resolved_commit="$REF"
  else
    resolved_commit="$(git ls-remote "https://github.com/$REPO" "$REF" | awk 'NR == 1 {print $1}')"
    [ -n "$resolved_commit" ] || die "Could not resolve $REPO@$REF."
  fi
  upstream_generator="$(sed -n -E 's/^GENERATOR_VERSION="([^"]+)"/\1/p' "$up_installer" | head -1)"
  [ -n "$upstream_generator" ] || die "Upstream installer has no generator version."
  jq --arg repo "$REPO" --arg ref "$REF" --arg commit "$resolved_commit" --arg version "$upstream_generator" '.sourceRepository = $repo | .trackingRef = $ref | .resolvedCommit = $commit | .generatorVersion = $version' "$SCAFFOLD_JSON" > "$candidate_scaffold"
  jq -e '.schemaVersion == 1' "$candidate_scaffold" >/dev/null || die "Updated scaffold metadata failed validation."
  jq -e 'type == "object"' "$candidate_devcontainer" >/dev/null || die "Generated devcontainer candidate failed validation."
  [ ! -s "$candidate_lock" ] || jq -e '.schemaVersion == 1' "$candidate_lock" >/dev/null || die "Generated dependency-lock candidate failed validation."
  backup="$(mktemp -d)"
  cp "$DOCKERFILE" "$backup/Dockerfile"; cp "$DEVCONTAINER_JSON" "$backup/devcontainer.json"; cp "$SCAFFOLD_DEST" "$backup/scaffold.json"; cp "$SELF_PATH" "$backup/install.sh"
  [ ! -f "$REPO_ROOT/.devcontainer/awscli.pub" ] || cp "$REPO_ROOT/.devcontainer/awscli.pub" "$backup/awscli.pub"
  [ ! -f "$REPO_ROOT/.devcontainer/dependencies.lock.json" ] || cp "$REPO_ROOT/.devcontainer/dependencies.lock.json" "$backup/dependencies.lock.json"
  rollback_update() { cp "$backup/Dockerfile" "$DOCKERFILE"; cp "$backup/devcontainer.json" "$DEVCONTAINER_JSON"; cp "$backup/scaffold.json" "$SCAFFOLD_DEST"; cp "$backup/install.sh" "$SELF_PATH"; [ ! -f "$backup/awscli.pub" ] || cp "$backup/awscli.pub" "$REPO_ROOT/.devcontainer/awscli.pub"; [ ! -f "$backup/dependencies.lock.json" ] || cp "$backup/dependencies.lock.json" "$REPO_ROOT/.devcontainer/dependencies.lock.json"; }
  trap rollback_update ERR
  cp "$candidate_dockerfile" "$DOCKERFILE"; cp "$candidate_devcontainer" "$DEVCONTAINER_JSON"
  [ ! -s "$candidate_aws" ] || cp "$candidate_aws" "$REPO_ROOT/.devcontainer/awscli.pub"
  [ ! -s "$candidate_lock" ] || cp "$candidate_lock" "$REPO_ROOT/.devcontainer/dependencies.lock.json"
  cp "$candidate_scaffold" "$SCAFFOLD_DEST"
  cp "$up_installer" "$SELF_PATH"
  chmod +x "$SELF_PATH"
  trap - ERR
  rm -rf "$backup" "$stage"
  echo
  info "bumped ${#BUMPED[@]} pin(s), skipped ${#SKIPPED_UPSTREAM_ONLY[@]} upstream-only, ${#SKIPPED_LOCAL_ONLY[@]} local-only"
  local b
  for b in ${BUMPED[@]+"${BUMPED[@]}"}; do
    info "  bumped: $b"
  done
  for b in ${SKIPPED_UPSTREAM_ONLY[@]+"${SKIPPED_UPSTREAM_ONLY[@]}"}; do
    info "  skipped (upstream-only, run install.sh update --full to adopt): $b"
  done
  for b in ${SKIPPED_LOCAL_ONLY[@]+"${SKIPPED_LOCAL_ONLY[@]}"}; do
    info "  skipped (local-only, no matching upstream key): $b"
  done
  rm -f "$up_dockerfile" "$up_devcontainer" "$up_awscli_pub" "$up_dependencies_lock" "$up_installer"
}

# ─────────────────────────────────────────────────────────────────────────────
# --full mode: re-run install.sh, overwriting .devcontainer/ wholesale
# ─────────────────────────────────────────────────────────────────────────────

# Dockerfile ARG name → --language/--tool/--cli token. Must cover every ARG
# install.sh can flip, or a round-trip through install.sh update silently drops that
# feature (see test.sh's token-set-coverage assertion in the source repo).
arg_token() {
  case "$1" in
    PYTHON)     echo "python" ;;
    GOLANG)     echo "go" ;;
    NODEJS)     echo "js" ;;
    DOTNET)     echo "dotnet" ;;
    AWSCLI)     echo "awscli" ;;
    AZCLI)      echo "azcli" ;;
    GHCLI)      echo "gh" ;;
    POWERSHELL) echo "pwsh" ;;
    AZPWSH)     echo "azpwsh" ;;
    CLAUDECODE) echo "claude" ;;
    CODEX)      echo "codex" ;;
    OPENCODE)   echo "opencode" ;;
    KIRO)       echo "kiro" ;;
    *)          return 1 ;;
  esac
}

run_full() {
  LANGS=(); while IFS= read -r token; do LANGS+=("$token"); done < <(jq -r '.languages[]' "$SCAFFOLD_JSON")
  TOOLS=(); while IFS= read -r token; do TOOLS+=("$token"); done < <(jq -r '.tools[]' "$SCAFFOLD_JSON")
  CLIS=(); while IFS= read -r token; do CLIS+=("$token"); done < <(jq -r '.clis[]' "$SCAFFOLD_JSON")
  [ "$REPLACE_LANGS" = true ] && LANGS=()
  [ "$REPLACE_TOOLS" = true ] && TOOLS=()
  if [ "$REPLACE_CLIS" = true ]; then
    REMOVED_CLIS=("${CLIS[@]+"${CLIS[@]}"}")
    CLIS=()
  else
    REMOVED_CLIS=()
  fi

  ARGS=(--target "$REPO_ROOT" --repo "$REPO" --ref "$REF")
  [ ${#LANGS[@]} -gt 0 ] && ARGS+=(--language "$(IFS=,; echo "${LANGS[*]}")")
  [ ${#TOOLS[@]} -gt 0 ] && ARGS+=(--tool "$(IFS=,; echo "${TOOLS[*]}")")
  [ ${#CLIS[@]} -gt 0 ] && ARGS+=(--cli "$(IFS=,; echo "${CLIS[*]}")")

  WANT_FULL_SKILLS="$(jq -r .skills "$SCAFFOLD_JSON")"
  WANT_FULL_EXTENSIONS="$(jq -r .extensions "$SCAFFOLD_JSON")"
  [ "$REPLACE_SKILLS" = true ] && WANT_FULL_SKILLS="$NEW_SKILLS"
  [ "$REPLACE_EXTENSIONS" = true ] && WANT_FULL_EXTENSIONS="$NEW_EXTENSIONS"
  [ "$WANT_FULL_SKILLS" = true ] && ARGS+=(--skills)
  [ "$WANT_FULL_EXTENSIONS" = true ] && ARGS+=(--extensions)
  # Guard the expansion: under `set -u`, macOS's bash 3.2 errors on "${arr[@]}"
  # when the array is empty (no `-- <args>` were passed). The ${arr[@]+...}
  # form expands to nothing when empty.
  ARGS+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})

  info "Detected languages: ${LANGS[*]:-none}"
  info "Detected tools: ${TOOLS[*]:-none}"
  info "Detected AI CLIs: ${CLIS[*]:-none}"
  info "Full update summary: restamp structural templates and managed files; languages=${LANGS[*]:-none}; tools=${TOOLS[*]:-none}; CLIs=${CLIS[*]:-none}; skills=$WANT_FULL_SKILLS; extensions=$WANT_FULL_EXTENSIONS"
  info "Re-running install.sh from $REPO@$REF ..."

  if [ -n "${INSTALL_SH_LOCAL_SOURCE:-}" ]; then
    bash "$INSTALL_SH_LOCAL_SOURCE/install.sh" "${ARGS[@]}"
  else
    curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/install.sh" | bash -s -- "${ARGS[@]}"
  fi
  local removed dir
  for removed in ${REMOVED_CLIS[@]+"${REMOVED_CLIS[@]}"}; do
    case "$removed" in claude) dir=".claude" ;; codex) dir=".codex" ;; opencode) dir=".opencode" ;; kiro) dir=".kiro" ;; esac
    info "Removed CLI $removed from active scaffold configuration; retained $REPO_ROOT/$dir (remove manually if desired)."
  done
}

EXPECTED_ARGS="$(jq -r '(.languages[] | {python:"PYTHON",go:"GOLANG",js:"NODEJS",dotnet:"DOTNET"}[.]), (.tools[] | {awscli:"AWSCLI",azcli:"AZCLI",gh:"GHCLI",pwsh:"POWERSHELL",azpwsh:"AZPWSH"}[.]), (.clis[] | {claude:"CLAUDECODE",codex:"CODEX",opencode:"OPENCODE",kiro:"KIRO"}[.])' "$SCAFFOLD_JSON" | sort)"
DETECTED_ARGS="$(sed -n -E 's/^ARG ([A-Z_]+)=true[[:space:]]*$/\1/p' "$DOCKERFILE" | sort)"
if [ "$EXPECTED_ARGS" != "$DETECTED_ARGS" ] && [ "$UPDATE_ACK_DRIFT" != true ]; then
  die "Detected feature state differs from scaffold.json; use --force to acknowledge drift."
fi

if [ "$FULL" = true ]; then
  run_full
else
  run_surgical
fi
}

if [ "${1:-}" = "update" ]; then
  shift
  run_update_mode "$@"
  exit 0
fi

# --- Defaults -----------------------------------------------------------------
REPO="lootem/devcontainer"
REF="main"
TARGET="."
FORCE=false
WANT_SKILLS=false
WANT_EXTENSIONS=false
ALLOW_BASE_ONLY=false
LANGS=()
TOOLS=()
CLIS=()

# Language token → Dockerfile ARG name.
lang_arg() {
  case "$1" in
    python) echo "PYTHON" ;;
    go)     echo "GOLANG" ;;
    js)     echo "NODEJS" ;;
    dotnet) echo "DOTNET" ;;
    *)      return 1 ;;
  esac
}
VALID_LANGS="python go js dotnet"

# Tool token → Dockerfile ARG name. Unlike languages, tools have no editor/
# gitignore/extension templates — they only flip a Dockerfile ARG. Note:
# azpwsh implies pwsh (the Dockerfile installs PowerShell if POWERSHELL or
# AZPWSH is true), so passing both is unnecessary but harmless.
tool_arg() {
  case "$1" in
    awscli) echo "AWSCLI" ;;
    azcli)  echo "AZCLI" ;;
    gh)     echo "GHCLI" ;;
    pwsh)   echo "POWERSHELL" ;;
    azpwsh) echo "AZPWSH" ;;
    *)      return 1 ;;
  esac
}
VALID_TOOLS="awscli azcli gh pwsh azpwsh"

# AI CLI token → Dockerfile ARG name. Selecting a CLI installs its binary and
# configures its native project-local state. All CLI ARGs default false in the
# Dockerfile; install.sh flips only the selected ones true.
cli_arg() {
  case "$1" in
    claude) echo "CLAUDECODE" ;;
    codex)  echo "CODEX" ;;
    opencode) echo "OPENCODE" ;;
    kiro) echo "KIRO" ;;
    *)      return 1 ;;
  esac
}
# Where each CLI loads project-level skills from (same SKILL.md format).
cli_skills_dir() {
  case "$1" in
    claude) echo ".claude/skills" ;;
    codex)  echo ".codex/skills" ;;
    opencode) echo ".opencode/skills" ;;
    kiro) echo ".kiro/skills" ;;
    *)      return 1 ;;
  esac
}
VALID_CLIS="claude codex opencode kiro"

# --- TTY-aware helpers ----------------------------------------------------------
HAVE_TTY=false
# Must actually be openable: existence/readable tests pass even when there is
# no controlling terminal (e.g. CI), where opening /dev/tty then fails.
if { exec 3</dev/tty; } 2>/dev/null; then
  HAVE_TTY=true
  exec 3<&-
fi

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "[install] $*"; }

ask() { # ask "prompt" -> prints the answer (empty if no tty)
  local ans=""
  if [ "$HAVE_TTY" = true ]; then
    read -r -p "$1" ans < /dev/tty || true
  fi
  printf '%s' "$ans"
}

# Sticky answer once the user picks "all"/"none" at any ask_yn prompt, so they
# aren't asked the same yes/no question repeatedly (e.g. once per gitignore
# or settings.json key conflict).
#
# It's kept in a FILE, not a shell variable, on purpose: ask_yn is always
# invoked inside command substitution ("$(ask_yn ...)"), and its callers
# (write_from_stdin/merge_*) often run on the right side of a pipe — both are
# subshells, so a plain `ANSWER_ALL=yes` assignment would vanish when the
# subshell exits and the choice would never stick. A file survives across them.
ANSWER_ALL_FILE=""   # set once we have a temp dir (see below); empty = disabled

ask_yn() { # ask_yn "prompt text (no trailing ?)" -> echoes "yes" or "no"
  if [ -n "$ANSWER_ALL_FILE" ] && [ -s "$ANSWER_ALL_FILE" ]; then
    cat "$ANSWER_ALL_FILE"
    return
  fi
  if [ "$FORCE" = true ]; then
    printf 'yes'
    return
  fi
  if [ "$HAVE_TTY" != true ]; then
    printf 'no'
    return
  fi
  local ans
  ans="$(ask "$1? [y/N/a=yes-to-all/o=no-to-all] ")"
  case "$ans" in
    y|Y|yes)  printf 'yes' ;;
    a|A|all)  [ -n "$ANSWER_ALL_FILE" ] && printf 'yes' > "$ANSWER_ALL_FILE"; printf 'yes' ;;
    o|O|none) [ -n "$ANSWER_ALL_FILE" ] && printf 'no'  > "$ANSWER_ALL_FILE"; printf 'no'  ;;
    *)        printf 'no' ;;
  esac
}

# --- Argument parsing -----------------------------------------------------------
add_langs() { # split a comma-separated list into LANGS
  local IFS=','
  for l in $1; do
    [ -n "$l" ] && LANGS+=("$l")
  done
}

add_tools() { # split a comma-separated list into TOOLS
  local IFS=','
  for t in $1; do
    [ -n "$t" ] && TOOLS+=("$t")
  done
}

add_clis() { # split a comma-separated list into CLIS
  local IFS=','
  for c in $1; do
    [ -n "$c" ] && CLIS+=("$c")
  done
}

# has_cli <name> -> 0 if <name> is in the selected CLIS, else 1
has_cli() {
  case " ${CLIS[*]:-} " in *" $1 "*) return 0 ;; esac
  return 1
}

usage() {
  cat <<EOF
Usage: install.sh [options]

  -l, --language <list>  Comma-separated or repeated languages ($VALID_LANGS)
  -T, --tool <list>      Comma-separated or repeated tools ($VALID_TOOLS)
  -c, --cli <list>       Comma-separated or repeated AI CLIs ($VALID_CLIS; default: none)
      --skills           Copy skills/ into each selected CLI's skills dir (default: off)
      --extensions       Add recommended VS Code extensions to devcontainer.json (default: off)
      --base-only        Generate the base container with no language (non-interactive)
  -t, --target <dir>     Target directory (default: current directory)
  -f, --force            Overwrite existing files without prompting
      --repo <owner/rep> Source repo (default: $REPO)
      --ref <ref>        Branch/tag/commit to clone (default: $REF)
  -h, --help             Show this help
EOF
}

update_kiro_dependency_lock() { # update_kiro_dependency_lock <semver>
  local version="$1"
  case "$version" in
    *[!0-9.]*|.*|*.|*..*) die "Kiro version must be a three-part semver (for example 2.15.2)." ;;
  esac
  [ "$(printf '%s' "$version" | awk -F. '{ print NF }')" -eq 3 ] \
    || die "Kiro version must be a three-part semver (for example 2.15.2)."

  command -v curl >/dev/null 2>&1 || die "Cannot update the dependency lock without 'curl'."
  command -v jq >/dev/null 2>&1 || die "Cannot update the dependency lock without 'jq'."
  command -v sha256sum >/dev/null 2>&1 || die "Cannot update the dependency lock without 'sha256sum'."

  local script_dir lock tmp final_lock base arch upstream_arch filename url archive hash
  local curl_args=(-fsSL)
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  lock="$script_dir/.devcontainer/dependencies.lock.json"
  [ -f "$lock" ] || die "Dependency lock not found: $lock"
  jq -e '.schemaVersion == 1 and (.kiro | type == "object")' "$lock" >/dev/null \
    || die "Existing dependency lock is missing schemaVersion 1 or the Kiro records."

  tmp="$(mktemp -d)"
  base="${KIRO_DOWNLOAD_BASE_URL:-https://desktop-release.q.us-east-1.amazonaws.com}"
  if [ -z "${KIRO_DOWNLOAD_BASE_URL:-}" ]; then
    curl_args=(--proto '=https' --tlsv1.2 -fsSL)
  fi
  for arch in amd64 arm64; do
    case "$arch" in
      amd64) upstream_arch="x86_64" ;;
      arm64) upstream_arch="aarch64" ;;
    esac
    filename="kirocli-${upstream_arch}-linux.tar.xz"
    url="${base%/}/${version}/${filename}"
    archive="$tmp/$filename"
    if ! curl "${curl_args[@]}" "$url" -o "$archive"; then
      rm -rf "$tmp"
      die "Could not download Kiro $arch artifact for version $version."
    fi
    hash="$(sha256sum "$archive" | awk '{ print $1 }')"
    case "$hash" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
      *) rm -rf "$tmp"; die "Could not calculate the Kiro $arch SHA-256." ;;
    esac
    [ "${#hash}" -eq 64 ] \
      || { rm -rf "$tmp"; die "Could not calculate the Kiro $arch SHA-256."; }
    jq --arg arch "$arch" --arg version "$version" --arg url "$url" --arg sha256 "$hash" \
      '.kiro[$arch] = {version: $version, url: $url, sha256: $sha256}' \
      "$lock" > "$tmp/lock.next"
    mv "$tmp/lock.next" "$tmp/lock.work"
    lock="$tmp/lock.work"
  done

  jq -e '
    .schemaVersion == 1
    and (.kiro.amd64.version == .kiro.arm64.version)
    and (.kiro.amd64.sha256 | test("^[0-9a-f]{64}$"))
    and (.kiro.arm64.sha256 | test("^[0-9a-f]{64}$"))
  ' "$lock" >/dev/null || { rm -rf "$tmp"; die "Generated Kiro dependency lock failed validation."; }
  final_lock="$(mktemp "$script_dir/.devcontainer/.dependencies.lock.XXXXXX")"
  cp "$lock" "$final_lock" \
    || { rm -f "$final_lock"; rm -rf "$tmp"; die "Could not prepare the atomic dependency-lock replacement."; }
  chmod 0644 "$final_lock"
  mv "$final_lock" "$script_dir/.devcontainer/dependencies.lock.json"
  rm -rf "$tmp"
  info "Locked Kiro $version for amd64 and arm64."
}

# Maintainer-only dependency refresh path. It is intentionally a narrow
# subcommand so Renovate can allowlist it without exposing a general shell.
if [ "${1:-}" = "dependency-lock" ]; then
  [ "$#" -eq 3 ] && [ "${2:-}" = "kiro" ] \
    || die "Usage: install.sh dependency-lock kiro <version>"
  update_kiro_dependency_lock "$3"
  exit 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    -l|--language) add_langs "$2"; shift 2 ;;
    --language=*)  add_langs "${1#*=}"; shift ;;
    -T|--tool)     add_tools "$2"; shift 2 ;;
    --tool=*)      add_tools "${1#*=}"; shift ;;
    -c|--cli)      add_clis "$2"; shift 2 ;;
    --cli=*)       add_clis "${1#*=}"; shift ;;
    --skills)      WANT_SKILLS=true; shift ;;
    --extensions)  WANT_EXTENSIONS=true; shift ;;
    --base-only)   ALLOW_BASE_ONLY=true; shift ;;
    -t|--target)   TARGET="$2"; shift 2 ;;
    --target=*)    TARGET="${1#*=}"; shift ;;
    -f|--force)    FORCE=true; shift ;;
    --repo)        REPO="$2"; shift 2 ;;
    --repo=*)      REPO="${1#*=}"; shift ;;
    --ref)         REF="$2"; shift 2 ;;
    --ref=*)       REF="${1#*=}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Unknown argument: $1 (see --help)" ;;
  esac
done

# --- Interactive fill-ins (need a tty) ------------------------------------------
if [ ${#LANGS[@]} -eq 0 ] && [ "$ALLOW_BASE_ONLY" != true ]; then
  if [ "$HAVE_TTY" = true ]; then
    info "Available languages: $VALID_LANGS"
    add_langs "$(ask 'Languages (comma-separated, blank for none): ')"
  else
    die "No --language given and no tty for a prompt. Pass --language."
  fi
fi

# AI CLIs: prompt when interactive and none were passed. Blank selects none.
if [ ${#CLIS[@]} -eq 0 ] && [ "$HAVE_TTY" = true ]; then
  info "Available AI CLIs: $VALID_CLIS"
  add_clis "$(ask 'AI CLIs (comma-separated, blank for none): ')"
fi

# Validate & de-duplicate language tokens.
# NB: iterate with the ${arr[@]+"${arr[@]}"} guard, not a bare "${arr[@]}".
# Under `set -u`, bash 3.2 (macOS's default /bin/bash) treats expanding an
# EMPTY array as an unbound-variable error; the guard expands to nothing when
# empty and to the quoted elements otherwise. Applies to every LANGS/TOOLS loop.
SEEN=" "
CLEAN_LANGS=()
for l in ${LANGS[@]+"${LANGS[@]}"}; do
  lang_arg "$l" >/dev/null 2>&1 || die "Unknown language '$l'. Valid: $VALID_LANGS"
  case "$SEEN" in *" $l "*) continue ;; esac
  SEEN="$SEEN$l "
  CLEAN_LANGS+=("$l")
done
LANGS=("${CLEAN_LANGS[@]:-}")
# Drop the empty placeholder that :-"" may leave when no langs selected.
[ "${LANGS[0]:-}" = "" ] && LANGS=()

# Validate & de-duplicate tool tokens.
SEEN=" "
CLEAN_TOOLS=()
for t in ${TOOLS[@]+"${TOOLS[@]}"}; do
  tool_arg "$t" >/dev/null 2>&1 || die "Unknown tool '$t'. Valid: $VALID_TOOLS"
  case "$SEEN" in *" $t "*) continue ;; esac
  SEEN="$SEEN$t "
  CLEAN_TOOLS+=("$t")
done
TOOLS=("${CLEAN_TOOLS[@]:-}")
# Drop the empty placeholder that :-"" may leave when no tools selected.
[ "${TOOLS[0]:-}" = "" ] && TOOLS=()

# Validate & de-duplicate AI CLI tokens.
SEEN=" "
CLEAN_CLIS=()
for c in ${CLIS[@]+"${CLIS[@]}"}; do
  cli_arg "$c" >/dev/null 2>&1 || die "Unknown CLI '$c'. Valid: $VALID_CLIS"
  case "$SEEN" in *" $c "*) continue ;; esac
  SEEN="$SEEN$c "
  CLEAN_CLIS+=("$c")
done
CLIS=("${CLEAN_CLIS[@]:-}")
[ "${CLIS[0]:-}" = "" ] && CLIS=()

if [ "$WANT_SKILLS" = true ] && [ ${#CLIS[@]} -eq 0 ]; then
  die "--skills requires at least one --cli selection."
fi

if [ "$WANT_SKILLS" = false ] && [ "$HAVE_TTY" = true ] && [ ${#CLIS[@]} -gt 0 ]; then
  case "$(ask 'Install skills into the selected CLIs'"'"' skills dirs? [y/N] ')" in
    y|Y|yes) WANT_SKILLS=true ;;
  esac
fi

if [ "$WANT_EXTENSIONS" = false ] && [ "$HAVE_TTY" = true ]; then
  case "$(ask 'Add recommended VS Code extensions to devcontainer.json? [y/N] ')" in
    y|Y|yes) WANT_EXTENSIONS=true ;;
  esac
fi

# --- Dependency checks ----------------------------------------------------------
ensure_cmd() { # ensure_cmd <command> [package]
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0

  echo "Missing required tool: $cmd" >&2
  local do_install=false
  if [ "$HAVE_TTY" = true ]; then
    case "$(ask "Install '$pkg' now? [y/N] ")" in y|Y|yes) do_install=true ;; esac
  fi
  [ "$do_install" = true ] || die "Cannot continue without '$cmd'. Install it and re-run."

  local sudo=""
  [ "$(id -u)" -ne 0 ] && sudo="sudo"
  if   command -v apt-get >/dev/null 2>&1; then $sudo apt-get update && $sudo apt-get install -y "$pkg"
  elif command -v dnf     >/dev/null 2>&1; then $sudo dnf install -y "$pkg"
  elif command -v pacman  >/dev/null 2>&1; then $sudo pacman -Sy --noconfirm "$pkg"
  elif command -v brew    >/dev/null 2>&1; then brew install "$pkg"
  else die "No supported package manager (apt/dnf/pacman/brew). Install '$cmd' manually."
  fi
  command -v "$cmd" >/dev/null 2>&1 || die "Installation of '$cmd' did not succeed."
}

ensure_cmd git
ensure_cmd jq

# --- Clone source repo ----------------------------------------------------------
SRC="$(mktemp -d)"
# Back the sticky yes-to-all/no-to-all choice with a file under $SRC so it
# survives the subshells ask_yn runs in (see the ANSWER_ALL_FILE note above).
ANSWER_ALL_FILE="$SRC/.answer_all"
cleanup() { rm -rf "$SRC"; }
trap cleanup EXIT

info "Cloning $REPO@$REF ..."
if printf '%s' "$REF" | grep -Eq '^[0-9a-f]{40}$'; then
  git clone "https://github.com/$REPO" "$SRC" >/dev/null 2>&1 \
    || die "Failed to clone https://github.com/$REPO for immutable commit $REF"
  git -C "$SRC" checkout -q --detach "$REF" || die "Commit $REF was not found in $REPO"
else
git clone --depth 1 --branch "$REF" "https://github.com/$REPO" "$SRC" >/dev/null 2>&1 \
  || die "Failed to clone https://github.com/$REPO@$REF"
fi

TPL="$SRC/templates"
DEVC="$SRC/.devcontainer"
[ -d "$TPL" ]  || die "Source has no templates/ directory."
[ -d "$DEVC" ] || die "Source has no .devcontainer/ directory."

mkdir -p "$TARGET"

# --- Overwrite-aware writers ----------------------------------------------------
may_write() { # may_write <dest>  -> 0 if we should write, 1 to skip
  local dest="$1"
  [ -e "$dest" ] || return 0
  if [ "$(ask_yn "Overwrite $dest")" = "yes" ]; then
    return 0
  fi
  info "Skipped $dest"
  return 1
}

write_from_stdin() { # write_from_stdin <dest>
  local dest="$1"
  if may_write "$dest"; then
    mkdir -p "$(dirname "$dest")"
    cat > "$dest"
    info "Wrote $dest"
  else
    cat >/dev/null
  fi
}

copy_verbatim() { # copy_verbatim <src> <dest>
  local src="$1" dest="$2"
  if may_write "$dest"; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    info "Wrote $dest"
  fi
}

# --- JSONC → JSON (strip // comments and trailing commas), portably -------------
strip_jsonc() { # strip_jsonc <file>  -> strict JSON on stdout
  # 1. Drop // comments (leave :// inside URLs alone).
  # 2. Drop trailing commas that precede a closing } or ] on a later line.
  sed -E 's#([^:])//.*#\1#; s#^[[:space:]]*//.*##' "$1" | awk '
    { n++; a[n]=$0 }
    END {
      for (i=1;i<=n;i++) {
        line=a[i]; j=i+1
        while (j<=n && a[j] ~ /^[[:space:]]*$/) j++
        if (j<=n && a[j] ~ /^[[:space:]]*[]}]/) sub(/,[[:space:]]*$/,"",line)
        print line
      }
    }'
}

# --- Merge-on-conflict writers ---------------------------------------------------
# Unlike may_write()/write_from_stdin() (whole-file overwrite-or-skip), these two
# combine generated content with whatever's already at dest instead of clobbering it.

merge_gitignore() { # merge_gitignore <dest>  (reads generated .gitignore on stdin)
  local dest="$1" generated
  generated="$(cat)"
  if [ ! -e "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$generated" > "$dest"
    info "Wrote $dest"
    return
  fi
  local to_add="" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    grep -qxF "$line" "$dest" && continue
    to_add+="$line"$'\n'
  done <<< "$generated"
  if [ -n "$to_add" ]; then
    if grep -qxF '# --- merged from generator ---' "$dest"; then
      printf '%s' "$to_add" >> "$dest"
    else
      { printf '\n# --- merged from generator ---\n'; printf '%s' "$to_add"; } >> "$dest"
    fi
    info "Merged new entries into $dest"
  else
    info "$dest already up to date"
  fi
}

merge_settings_json() { # merge_settings_json <dest>  (reads generated JSON on stdin)
  local dest="$1" generated
  generated="$(cat)"
  if [ ! -e "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    printf '%s' "$generated" > "$dest"
    info "Wrote $dest"
    return
  fi
  local existing merged key gval eval_ decision
  existing="$(strip_jsonc "$dest")"
  merged="$existing"
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    gval="$(printf '%s' "$generated" | jq -c --arg k "$key" '.[$k]')"
    if ! printf '%s' "$existing" | jq -e --arg k "$key" 'has($k)' >/dev/null; then
      merged="$(printf '%s' "$merged" | jq --arg k "$key" --argjson v "$gval" '.[$k] = $v')"
      continue
    fi
    eval_="$(printf '%s' "$existing" | jq -c --arg k "$key" '.[$k]')"
    [ "$eval_" = "$gval" ] && continue
    decision="$(ask_yn "$dest: key \"$key\" differs (existing: $eval_ / generated: $gval) — use generated value")"
    [ "$decision" = "yes" ] && merged="$(printf '%s' "$merged" | jq --arg k "$key" --argjson v "$gval" '.[$k] = $v')"
  done < <(printf '%s' "$generated" | jq -r 'keys[]')
  printf '%s\n' "$merged" | jq '.' > "$dest"
  info "Merged $dest"
}

merge_json_boolean() { # merge_json_boolean <dest> <dotted-key-path> <true|false>
  local dest="$1" key="$2" value="$3" existing
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ]; then
    existing="$(strip_jsonc "$dest")"
  else
    existing='{}'
  fi
  printf '%s' "$existing" | jq --arg key "$key" --argjson value "$value" \
    'setpath(($key | split(".")); $value)' > "$dest.tmp"
  mv "$dest.tmp" "$dest"
  info "Merged $dest"
}

merge_codex_native_config() { # merge update policy and Azure provider template
  local dest="$1" has_azure=false
  mkdir -p "$(dirname "$dest")"
  [ -e "$dest" ] || : > "$dest"
  grep -qE '^[[:space:]]*\[model_providers\.azure\][[:space:]]*$' "$dest" \
    && has_azure=true
  awk '
    BEGIN { in_table=0; wrote=0 }
    /^\[/ && !in_table {
      if (!wrote) print "check_for_update_on_startup = false"
      wrote=1
      in_table=1
    }
    !in_table && /^[[:space:]]*check_for_update_on_startup[[:space:]]*=/ {
      if (!wrote) print "check_for_update_on_startup = false"
      wrote=1
      next
    }
    { print }
    END {
      if (!wrote) print "check_for_update_on_startup = false"
    }
  ' "$dest" > "$dest.tmp"
  if [ "$has_azure" = false ]; then
    cat >> "$dest.tmp" <<'EOF'

# Azure OpenAI provider. Replace YOUR_RESOURCE_NAME, then set the top-level
# model_provider = "azure" and model = "<deployment-name>" to select it.
[model_providers.azure]
name = "Azure OpenAI"
base_url = "https://YOUR_RESOURCE_NAME.openai.azure.com/openai"
env_key = "AZURE_OPENAI_API_KEY"
wire_api = "responses"
query_params = { api-version = "2025-04-01-preview" }
EOF
  fi
  mv "$dest.tmp" "$dest"
  info "Merged $dest"
}

# ═══ Assembly ═══════════════════════════════════════════════════════════════════

# --- .devcontainer/ files --------------------------------------------------------
# Generate the clean compose without build args, adding active native state
# configuration only for selected CLIs. Provider mappings remain explicit but
# commented until the user opts into them.
CLI_ENV="$SRC/cli.environment"
CLI_VOLUMES="$SRC/cli.volumes"
: > "$CLI_ENV"
: > "$CLI_VOLUMES"
if has_cli claude; then
  printf '%s\n' \
    '      CLAUDE_CONFIG_DIR: /app/.claude' \
    '      DISABLE_AUTOUPDATER: "1"' >> "$CLI_ENV"
fi
if has_cli codex; then
  printf '%s\n' '      CODEX_HOME: /app/.codex' >> "$CLI_ENV"
fi
if has_cli opencode; then
  printf '%s\n' \
    '      OPENCODE_CONFIG: /app/.opencode/opencode.json' \
    '      OPENCODE_CONFIG_DIR: /app/.opencode' \
    '      OPENCODE_DISABLE_AUTOUPDATE: "1"' >> "$CLI_ENV"
  printf '%s\n' \
    '      - ../.opencode/data:/home/vscode/.local/share/opencode' >> "$CLI_VOLUMES"
fi
if has_cli kiro; then
  printf '%s\n' '      KIRO_HOME: /app/.kiro' >> "$CLI_ENV"
fi
[ -s "$CLI_ENV" ] || printf '%s\n' '      {}' >> "$CLI_ENV"
render_compose() { # render_compose <template-or-existing-compose>
  awk -v env_file="$CLI_ENV" -v volumes_file="$CLI_VOLUMES" '
  /# __CLI_ENVIRONMENT_BEGIN__/ {
    print
    while ((getline line < env_file) > 0) print line
    close(env_file)
    skip_environment=1
    next
  }
  skip_environment && /# __CLI_ENVIRONMENT_END__/ {
    skip_environment=0
    print
    next
  }
  skip_environment { next }
  /# __CLI_VOLUMES_BEGIN__/ {
    print
    while ((getline line < volumes_file) > 0) print line
    close(volumes_file)
    skip_volumes=1
    next
  }
  skip_volumes && /# __CLI_VOLUMES_END__/ {
    skip_volumes=0
    print
    next
  }
  skip_volumes { next }
  { print }
  ' "$1"
}

COMPOSE_DEST="$TARGET/.devcontainer/docker-compose.yml"
if [ -f "$COMPOSE_DEST" ] \
   && grep -qF '# __CLI_ENVIRONMENT_BEGIN__' "$COMPOSE_DEST" \
   && grep -qF '# __CLI_ENVIRONMENT_END__' "$COMPOSE_DEST" \
   && grep -qF '# __CLI_VOLUMES_BEGIN__' "$COMPOSE_DEST" \
   && grep -qF '# __CLI_VOLUMES_END__' "$COMPOSE_DEST"; then
  render_compose "$COMPOSE_DEST" > "$COMPOSE_DEST.tmp"
  mv "$COMPOSE_DEST.tmp" "$COMPOSE_DEST"
  info "Merged managed CLI configuration into $COMPOSE_DEST"
else
  render_compose "$TPL/docker-compose.yml" | write_from_stdin "$COMPOSE_DEST"
fi

# Merge the native update-disable settings without replacing unrelated state.
has_cli claude && merge_json_boolean "$TARGET/.claude/settings.json" autoUpdates false
has_cli codex && merge_codex_native_config "$TARGET/.codex/config.toml"
has_cli opencode && merge_json_boolean "$TARGET/.opencode/opencode.json" autoupdate false
has_cli kiro && merge_json_boolean "$TARGET/.kiro/settings/cli.json" app.disableAutoupdates true

[ -f "$DEVC/awscli.pub" ] && copy_verbatim "$DEVC/awscli.pub" "$TARGET/.devcontainer/awscli.pub"
[ -f "$DEVC/dependencies.lock.json" ] \
  && copy_verbatim "$DEVC/dependencies.lock.json" "$TARGET/.devcontainer/dependencies.lock.json"

# --- .devcontainer/Dockerfile with language + tool + CLI ARGs flipped to true ---
DOCKERFILE_TMP="$SRC/Dockerfile.built"
cp "$DEVC/Dockerfile" "$DOCKERFILE_TMP"
for l in ${LANGS[@]+"${LANGS[@]}"}; do
  arg="$(lang_arg "$l")"
  sed "s#^ARG ${arg}=false#ARG ${arg}=true#" "$DOCKERFILE_TMP" > "$DOCKERFILE_TMP.new"
  mv "$DOCKERFILE_TMP.new" "$DOCKERFILE_TMP"
  if ! grep -q "^ARG ${arg}=true" "$DOCKERFILE_TMP"; then
    die "Could not enable '$l' — no 'ARG ${arg}=false' line in Dockerfile."
  fi
done
for t in ${TOOLS[@]+"${TOOLS[@]}"}; do
  arg="$(tool_arg "$t")"
  sed "s#^ARG ${arg}=false#ARG ${arg}=true#" "$DOCKERFILE_TMP" > "$DOCKERFILE_TMP.new"
  mv "$DOCKERFILE_TMP.new" "$DOCKERFILE_TMP"
  if ! grep -q "^ARG ${arg}=true" "$DOCKERFILE_TMP"; then
    die "Could not enable '$t' — no 'ARG ${arg}=false' line in Dockerfile."
  fi
done
for c in ${CLIS[@]+"${CLIS[@]}"}; do
  arg="$(cli_arg "$c")"
  sed "s#^ARG ${arg}=false#ARG ${arg}=true#" "$DOCKERFILE_TMP" > "$DOCKERFILE_TMP.new"
  mv "$DOCKERFILE_TMP.new" "$DOCKERFILE_TMP"
  if ! grep -q "^ARG ${arg}=true" "$DOCKERFILE_TMP"; then
    die "Could not enable CLI '$c' — no 'ARG ${arg}=false' line in Dockerfile."
  fi
done
copy_verbatim "$DOCKERFILE_TMP" "$TARGET/.devcontainer/Dockerfile"

# --- .devcontainer/devcontainer.json, extensions merged + deduped (opt-in) ------
if [ "$WANT_EXTENSIONS" = true ]; then
  EXT_FILES=("$DEVC/devcontainer.json")
  for l in ${LANGS[@]+"${LANGS[@]}"}; do
    [ -f "$TPL/$l/extensions.json" ] && EXT_FILES+=("$TPL/$l/extensions.json")
  done
  jq -s '
    .[0] as $dc
    | (($dc.customizations.vscode.extensions // []) + ((.[1:] | add) // [])) | unique as $exts
    | $dc | .customizations.vscode.extensions = $exts
  ' "${EXT_FILES[@]}" | write_from_stdin "$TARGET/.devcontainer/devcontainer.json"
else
  jq 'del(.customizations.vscode.extensions)' "$DEVC/devcontainer.json" \
    | write_from_stdin "$TARGET/.devcontainer/devcontainer.json"
fi

# --- .vscode/settings.json = base settings + each language's settings, merged
# into any existing file (conflicting keys prompt; see merge_settings_json) ------
SETTINGS_STRIPPED=("$SRC/base.settings.json")
strip_jsonc "$TPL/basesettings.json" > "$SRC/base.settings.json"
for l in ${LANGS[@]+"${LANGS[@]}"}; do
  if [ -f "$TPL/$l/settings.json" ]; then
    strip_jsonc "$TPL/$l/settings.json" > "$SRC/$l.settings.json"
    SETTINGS_STRIPPED+=("$SRC/$l.settings.json")
  fi
done
jq -s 'reduce .[] as $o ({}; . * $o)' "${SETTINGS_STRIPPED[@]}" \
  | merge_settings_json "$TARGET/.vscode/settings.json"

# --- .gitignore = basegitignore + each language's <lang>gitignore, merged into
# any existing file by appending missing lines (see merge_gitignore) --------------
{
  cat "$TPL/basegitignore"
  for l in ${LANGS[@]+"${LANGS[@]}"}; do
    for gi in "$TPL/$l"/*gitignore; do
      [ -f "$gi" ] || continue
      printf '\n# --- %s ---\n' "$l"
      cat "$gi"
    done
  done
} | merge_gitignore "$TARGET/.gitignore"

# --- Per-language extra files (verbatim) -----------------------------------------
for l in ${LANGS[@]+"${LANGS[@]}"}; do
  case "$l" in
    python)
      [ -f "$TPL/python/launch.json" ] && copy_verbatim "$TPL/python/launch.json" "$TARGET/.vscode/launch.json"
      ;;
    js)
      [ -f "$TPL/js/pnpm-workspace.yaml" ] && copy_verbatim "$TPL/js/pnpm-workspace.yaml" "$TARGET/pnpm-workspace.yaml"
      ;;
  esac
done

# --- Provider environment example ----------------------------------------------
[ -f "$SRC/.env.example" ] && copy_verbatim "$SRC/.env.example" "$TARGET/.env.example"

# --- Skills (optional) — copied into each selected CLI's skills dir ---------------
# claude → .claude/skills, codex → .codex/skills, opencode →
# .opencode/skills, kiro → .kiro/skills (same SKILL.md format). All are kept
# committable by the generated .gitignore.
SKILLS_DIRS=()
if [ "$WANT_SKILLS" = true ]; then
  if [ -d "$SRC/skills" ]; then
    for c in ${CLIS[@]+"${CLIS[@]}"}; do
      dir="$(cli_skills_dir "$c")"
      if may_write "$TARGET/$dir"; then
        mkdir -p "$TARGET/$dir"
        cp -R "$SRC/skills/." "$TARGET/$dir/"
        # Maintainer-only tool for re-vendoring skills/ itself — irrelevant
        # (and not meant to run) inside a generated project's skills dir.
        rm -f "$TARGET/$dir/vendor-matt-pocock-skills.sh"
        info "Wrote $TARGET/$dir/"
        SKILLS_DIRS+=("$dir")
      fi
    done
  else
    info "No skills/ directory in source; skipping."
  fi
fi

# --- Scaffold metadata ----------------------------------------------------------
RESOLVED_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
jq -n \
  --argjson schemaVersion 1 \
  --arg sourceRepository "$REPO" \
  --arg trackingRef "$REF" \
  --arg resolvedCommit "$RESOLVED_COMMIT" \
  --arg generatorVersion "$GENERATOR_VERSION" \
  --argjson languages "$(printf '%s\n' "${LANGS[@]+"${LANGS[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson tools "$(printf '%s\n' "${TOOLS[@]+"${TOOLS[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson clis "$(printf '%s\n' "${CLIS[@]+"${CLIS[@]}"}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  --argjson skills "$WANT_SKILLS" \
  --argjson extensions "$WANT_EXTENSIONS" \
  '{schemaVersion: $schemaVersion, sourceRepository: $sourceRepository, trackingRef: $trackingRef, resolvedCommit: $resolvedCommit, generatorVersion: $generatorVersion, languages: $languages, tools: $tools, clis: $clis, skills: $skills, extensions: $extensions}' \
  | write_from_stdin "$TARGET/.devcontainer/scaffold.json"

# Replace the checked-in installer last so a successful update never truncates itself mid-run.
[ -f "$SRC/install.sh" ] && copy_verbatim "$SRC/install.sh" "$TARGET/.devcontainer/install.sh"
[ -f "$TARGET/.devcontainer/install.sh" ] && chmod +x "$TARGET/.devcontainer/install.sh"

# --- Summary --------------------------------------------------------------------
echo
info "Done. Target: $TARGET"
if [ ${#LANGS[@]} -gt 0 ]; then
  info "Languages enabled: ${LANGS[*]}"
else
  info "Languages enabled: (none — base devcontainer only)"
fi
[ ${#TOOLS[@]} -gt 0 ] && info "Tools enabled: ${TOOLS[*]}"
info "AI CLIs enabled: ${CLIS[*]}"
[ "$WANT_SKILLS" = true ] && [ ${#SKILLS_DIRS[@]} -gt 0 ] && info "Skills installed to: ${SKILLS_DIRS[*]}"
[ "$WANT_EXTENSIONS" = true ] && info "Recommended VS Code extensions added to devcontainer.json"
exit 0
