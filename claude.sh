#!/usr/bin/env bash
# claude.sh
# Usage: ./claude.sh [bedrock|foundry|api]
#        ./claude.sh keys init|edit
#        No argument → runs with default CLI params only.

set -euo pipefail

# ─── Default CLI params (edit freely) ────────────────────────────────────────
CLAUDE_PARAMS=(
  "--setting-sources" "project"
  "--effort" "medium"
  "--permission-mode" "auto"
  # "--model" "claude-sonnet-5"
)

# Path to your .env file (non-secret config only — see keys init/edit for secrets)
ENV_FILE="${ENV_FILE:-.env}"

# Durable secrets live gpg-encrypted at rest; decrypted to memory only, never to disk.
# The keys file's content — not any hardcoded variable list — decides what's secret:
# whatever KEY=VALUE lines you put in it are exported when a mode needs them.
KEYS_GPG="${KEYS_GPG:-.env.keys.gpg}"

# ─── Helpers ──────────────────────────────────────────────────────────────────
die()          { echo "Error: $*" >&2; exit 1; }
info()         { echo "[claude-start] $*"; }

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || die ".env file not found at '${file}'"
  # Export every valid KEY=VALUE line; skip comments and blanks
  set -a
  # shellcheck source=/dev/null
  source "$file"
  set +a
}

# ─── TTY-aware prompt ─────────────────────────────────────────────────────────
# Prompts read from /dev/tty (like install.sh's ask()) so piping something into
# claude.sh's own stdin can't be hijacked into answering a secret prompt; when
# there's no controlling terminal (CI), fall back to plain stdin.
HAVE_TTY=false
if { exec 3</dev/tty; } 2>/dev/null; then
  HAVE_TTY=true
  exec 3<&-
fi

read_secret() { # read_secret <prompt> -> prints the entered value
  local prompt="$1" val
  if [[ "$HAVE_TTY" == true ]]; then
    read -r -s -p "$prompt" val < /dev/tty
    echo >&2
  else
    read -r val
  fi
  printf '%s' "$val"
}

# Reads KEY=VALUE lines until a blank line/EOF. A key with no value (`KEY=`)
# deletes that key; otherwise later lines override earlier ones (including
# lines from <seed-file>, if given). Prints the merged set, one KEY=VALUE per
# line, sorted.
prompt_kv() { # prompt_kv [seed-file] -> prints merged KEY=VALUE lines
  local seed="${1:-}"
  local -A kv
  local key val line src
  if [[ -n "$seed" && -f "$seed" ]]; then
    while IFS='=' read -r key val; do
      [[ -z "$key" || "$key" == \#* ]] && continue
      kv["$key"]="$val"
    done < "$seed"
  fi
  [[ "$HAVE_TTY" == true ]] && src="/dev/tty" || src="/dev/stdin"
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" == \#* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    [[ -z "$key" ]] && continue
    if [[ -z "$val" ]]; then
      unset "kv[$key]"
    else
      kv["$key"]="$val"
    fi
  done < "$src"
  for key in "${!kv[@]}"; do
    printf '%s=%s\n' "$key" "${kv[$key]}"
  done | sort
}

# ─── Secrets: decrypt-to-memory only, never written to disk ─────────────────
TMP_CLEANUP=()
cleanup_tmp() {
  local f
  for f in "${TMP_CLEANUP[@]:-}"; do
    [[ -n "$f" && -f "$f" ]] || continue
    if command -v shred >/dev/null 2>&1; then
      shred -u "$f" 2>/dev/null || rm -f "$f"
    else
      : > "$f" 2>/dev/null || true
      rm -f "$f"
    fi
  done
}
trap cleanup_tmp EXIT

register_tmp() { TMP_CLEANUP+=("$1"); }

gpg_encrypt() { # gpg_encrypt <plaintext-file> <passphrase>
  printf '%s' "$2" | gpg --batch --yes --passphrase-fd 0 --symmetric --cipher-algo AES256 \
    --output "$KEYS_GPG" "$1"
}

gpg_decrypt() { # gpg_decrypt <passphrase> -> prints decrypted content on stdout
  printf '%s' "$1" | gpg --batch --yes --passphrase-fd 0 --decrypt "$KEYS_GPG" 2>/dev/null
}

new_passphrase() { # new_passphrase <verb> -> prints passphrase, dies on mismatch
  local pass confirm
  pass="$(read_secret "Passphrase to $1 ${KEYS_GPG}: ")"
  confirm="$(read_secret "Confirm passphrase: ")"
  [[ "$pass" == "$confirm" ]] || die "Passphrases did not match; aborting."
  printf '%s' "$pass"
}

# Decrypt $KEYS_GPG and export every KEY=VALUE line into the current process env.
load_keys_file() {
  [[ -f "$KEYS_GPG" ]] || die "'${KEYS_GPG}' not found. Run './claude.sh keys init' first."
  local pass decrypted
  pass="$(read_secret "Passphrase for ${KEYS_GPG}: ")"
  decrypted="$(gpg_decrypt "$pass")" || die "Failed to decrypt '${KEYS_GPG}' (wrong passphrase?)"
  unset pass
  local line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    export "$line"
  done <<< "$decrypted"
  unset decrypted
}

# Vars whose name suggests a durable secret, auto-detected out of $ENV_FILE
# for migration convenience. Not an allow-list for what the keys file may
# hold — you can type any KEY=VALUE at the keys init/edit prompt regardless
# of name (e.g. AWS_ACCESS_KEY_ID, which this pattern doesn't match).
SECRET_NAME_PATTERN='^[A-Za-z_]*(TOKEN|API_KEY)[A-Za-z_]*=.+$'

keys_init() {
  [[ -f "$KEYS_GPG" ]] && info "'${KEYS_GPG}' already exists; this will overwrite it."

  local seed
  seed="$(mktemp)"
  register_tmp "$seed"
  [[ -f "$ENV_FILE" ]] && grep -E "$SECRET_NAME_PATTERN" "$ENV_FILE" > "$seed" 2>/dev/null || true

  if [[ -s "$seed" ]]; then
    info "Detected likely secrets in ${ENV_FILE} (will be migrated):"
    while IFS='=' read -r key _; do info "  ${key}"; done < "$seed"
  fi
  info "Enter any other secrets as KEY=VALUE (e.g. AWS_ACCESS_KEY_ID=...)."
  info "Blank line/Ctrl-D to finish and encrypt into ${KEYS_GPG}."

  local tmp
  tmp="$(mktemp)"
  register_tmp "$tmp"
  chmod 600 "$tmp"
  prompt_kv "$seed" > "$tmp"

  grep -qE '^[A-Za-z_][A-Za-z0-9_]*=.+$' "$tmp" || die "No secret values provided; aborting keys init."

  local pass
  pass="$(new_passphrase "encrypt")"
  gpg_encrypt "$tmp" "$pass"
  unset pass

  # Whatever keys ended up in the keys file no longer belong in $ENV_FILE too —
  # the encrypted file is the only on-disk copy.
  if [[ -f "$ENV_FILE" ]]; then
    local names pattern envtmp
    names="$(grep -Eo '^[A-Za-z_][A-Za-z0-9_]*=' "$tmp" | sed 's/=$//' | sort -u)"
    if [[ -n "$names" ]]; then
      pattern="$(printf '%s\n' "$names" | paste -sd'|' -)"
      envtmp="$(mktemp)"
      register_tmp "$envtmp"
      grep -Ev "^(${pattern})=" "$ENV_FILE" > "$envtmp" || true
      mv "$envtmp" "$ENV_FILE"
    fi
  fi

  info "'${KEYS_GPG}' created. Secret values migrated out of '${ENV_FILE}'."
}

keys_edit() {
  [[ -f "$KEYS_GPG" ]] || die "'${KEYS_GPG}' not found. Run './claude.sh keys init' first."

  local pass current
  pass="$(read_secret "Passphrase for ${KEYS_GPG}: ")"
  current="$(mktemp)"
  register_tmp "$current"
  chmod 600 "$current"
  gpg_decrypt "$pass" > "$current" || die "Failed to decrypt '${KEYS_GPG}' (wrong passphrase?)"

  info "Current secrets in ${KEYS_GPG}:"
  while IFS='=' read -r key _; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    info "  ${key}"
  done < "$current"
  info "Type KEY=VALUE to add or replace one, KEY= (empty value) to remove one."
  info "Blank line/Ctrl-D to finish and save; anything untouched is kept as-is."

  local new
  new="$(mktemp)"
  register_tmp "$new"
  chmod 600 "$new"
  prompt_kv "$current" > "$new"

  grep -qE '^[A-Za-z_][A-Za-z0-9_]*=.+$' "$new" || die "No secrets left; aborting (no changes written)."

  gpg_encrypt "$new" "$pass"
  unset pass

  info "'${KEYS_GPG}' updated."
}

# ─── keys subcommand ──────────────────────────────────────────────────────────
if [[ "${1:-}" == "keys" ]]; then
  case "${2:-}" in
    init) keys_init; exit 0 ;;
    edit) keys_edit; exit 0 ;;
    *)    echo "Usage: $0 keys [init|edit]" >&2; exit 1 ;;
  esac
fi

# ─── Auth mode ────────────────────────────────────────────────────────────────
AUTH_MODE="${1:-}"

case "$AUTH_MODE" in

  bedrock)
    info "Mode: AWS Bedrock"
    load_env_file "$ENV_FILE"
    [[ -f "$KEYS_GPG" ]] && load_keys_file

    # Always required
    export CLAUDE_CODE_USE_BEDROCK=1
    export AWS_REGION="${AWS_REGION:?Set AWS_REGION in ${ENV_FILE}}"

    # Auth priority: Bedrock API key > SSO profile > access key
    if [[ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]]; then
      info "Bedrock auth: API key (AWS_BEARER_TOKEN_BEDROCK)"
      export AWS_BEARER_TOKEN_BEDROCK

    elif [[ -n "${AWS_PROFILE:-}" ]]; then
      info "Bedrock auth: SSO profile (${AWS_PROFILE})"
      export AWS_PROFILE

    elif [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
      info "Bedrock auth: access key"
      export AWS_ACCESS_KEY_ID
      export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?AWS_ACCESS_KEY_ID set but AWS_SECRET_ACCESS_KEY missing}"
      # Optional — only export if present
      [[ -n "${AWS_SESSION_TOKEN:-}" ]] && export AWS_SESSION_TOKEN

    else
      die "No Bedrock credentials found. Set AWS_BEARER_TOKEN_BEDROCK or AWS_ACCESS_KEY_ID via './claude.sh keys init', or AWS_PROFILE in '${ENV_FILE}'."
    fi

    CLAUDE_PARAMS+=("--bedrock")
    ;;

  foundry)
    info "Mode: Azure AI Foundry"
    load_env_file "$ENV_FILE"
    [[ -f "$KEYS_GPG" ]] && load_keys_file

    # Always required
    export CLAUDE_CODE_USE_FOUNDRY=1
    export ANTHROPIC_FOUNDRY_RESOURCE="${ANTHROPIC_FOUNDRY_RESOURCE:?Set ANTHROPIC_FOUNDRY_RESOURCE in ${ENV_FILE}}"

    # Auth priority: API key > SDK (Entra ID / az login)
    if [[ -n "${ANTHROPIC_FOUNDRY_API_KEY:-}" ]]; then
      info "Foundry auth: API key"
      export ANTHROPIC_FOUNDRY_API_KEY
    else
      info "Foundry auth: SDK / Entra ID (az login)"
      az account show >/dev/null 2>&1 || die "az CLI not logged in. Run 'az login' first."
    fi
    ;;

  api)
    info "Mode: Anthropic API  (key from ${KEYS_GPG})"
    load_keys_file
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] \
      || die "ANTHROPIC_API_KEY not found in '${KEYS_GPG}'. Run './claude.sh keys init'."
    export ANTHROPIC_API_KEY
    ;;

  "")
    info "Mode: default  (no auth override)"
    ;;

  *)
    echo "Usage: $0 [bedrock|foundry|api]" >&2
    exit 1
    ;;

esac

# -- Set global vars: https://code.claude.com/docs/en/env-vars
export CLAUDE_CONFIG_DIR=./.claude

# -- Launch
mkdir -p "$CLAUDE_CONFIG_DIR"
exec claude "${CLAUDE_PARAMS[@]}"
