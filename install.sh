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

# --- Defaults -----------------------------------------------------------------
REPO="lootem/devcontainer"
REF="main"
TARGET="."
FORCE=false
WANT_SKILLS=false
WANT_EXTENSIONS=false
LANGS=()
TOOLS=()

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

usage() {
  cat <<EOF
Usage: install.sh [options]

  -l, --language <list>  Comma-separated or repeated languages ($VALID_LANGS)
  -T, --tool <list>      Comma-separated or repeated tools ($VALID_TOOLS)
      --skills           Copy skills/ into .claude/skills/ (default: off)
      --extensions       Add recommended VS Code extensions to devcontainer.json (default: off)
  -t, --target <dir>     Target directory (default: current directory)
  -f, --force            Overwrite existing files without prompting
      --repo <owner/rep> Source repo (default: $REPO)
      --ref <ref>        Branch/tag/commit to clone (default: $REF)
  -h, --help             Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -l|--language) add_langs "$2"; shift 2 ;;
    --language=*)  add_langs "${1#*=}"; shift ;;
    -T|--tool)     add_tools "$2"; shift 2 ;;
    --tool=*)      add_tools "${1#*=}"; shift ;;
    --skills)      WANT_SKILLS=true; shift ;;
    --extensions)  WANT_EXTENSIONS=true; shift ;;
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
if [ ${#LANGS[@]} -eq 0 ]; then
  if [ "$HAVE_TTY" = true ]; then
    info "Available languages: $VALID_LANGS"
    add_langs "$(ask 'Languages (comma-separated, blank for none): ')"
  else
    die "No --language given and no tty for a prompt. Pass --language."
  fi
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

if [ "$WANT_SKILLS" = false ] && [ "$HAVE_TTY" = true ]; then
  case "$(ask 'Install Claude skills into .claude/skills/? [y/N] ')" in
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
git clone --depth 1 --branch "$REF" "https://github.com/$REPO" "$SRC" >/dev/null 2>&1 \
  || die "Failed to clone https://github.com/$REPO@$REF"

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

# ═══ Assembly ═══════════════════════════════════════════════════════════════════

# --- .devcontainer/ verbatim files -----------------------------------------------
copy_verbatim "$DEVC/docker-compose.yml" "$TARGET/.devcontainer/docker-compose.yml"
[ -f "$DEVC/awscli.pub" ] && copy_verbatim "$DEVC/awscli.pub" "$TARGET/.devcontainer/awscli.pub"
if [ -f "$DEVC/update.sh" ]; then
  copy_verbatim "$DEVC/update.sh" "$TARGET/.devcontainer/update.sh"
  [ -f "$TARGET/.devcontainer/update.sh" ] && chmod +x "$TARGET/.devcontainer/update.sh"
fi

# --- .devcontainer/Dockerfile with language + tool ARGs flipped to true ---------
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

# --- Root helper files (always) --------------------------------------------------
if [ -f "$SRC/claude.sh" ]; then
  copy_verbatim "$SRC/claude.sh" "$TARGET/claude.sh"
  [ -f "$TARGET/claude.sh" ] && chmod +x "$TARGET/claude.sh"
fi
[ -f "$SRC/.env.example" ] && copy_verbatim "$SRC/.env.example" "$TARGET/.env.example"

# --- Skills (optional; left untracked via .claude/ gitignore) --------------------
if [ "$WANT_SKILLS" = true ]; then
  if [ -d "$SRC/skills" ]; then
    if may_write "$TARGET/.claude/skills"; then
      mkdir -p "$TARGET/.claude/skills"
      cp -R "$SRC/skills/." "$TARGET/.claude/skills/"
      # Maintainer-only tool for re-vendoring skills/ itself — irrelevant
      # (and not meant to run) inside a generated project's .claude/skills/.
      rm -f "$TARGET/.claude/skills/vendor-matt-pocock-skills.sh"
      info "Wrote $TARGET/.claude/skills/"
    fi
  else
    info "No skills/ directory in source; skipping."
  fi
fi

# --- Summary --------------------------------------------------------------------
echo
info "Done. Target: $TARGET"
if [ ${#LANGS[@]} -gt 0 ]; then
  info "Languages enabled: ${LANGS[*]}"
else
  info "Languages enabled: (none — base devcontainer only)"
fi
[ ${#TOOLS[@]} -gt 0 ] && info "Tools enabled: ${TOOLS[*]}"
[ "$WANT_SKILLS" = true ] && info "Skills installed to .claude/skills/ (untracked)"
[ "$WANT_EXTENSIONS" = true ] && info "Recommended VS Code extensions added to devcontainer.json"
exit 0
