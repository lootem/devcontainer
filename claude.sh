#!/usr/bin/env bash
# claude.sh
# Usage: ./claude.sh            → auth mode is inferred from the environment
#        ./claude.sh keys init|edit
#
# The auth backend is no longer passed as an argument. It is inferred from the
# environment variables that are already set (in your shell or in $ENV_FILE):
#   bedrock  ← CLAUDE_CODE_USE_BEDROCK / AWS_REGION / AWS_PROFILE /
#              AWS_BEARER_TOKEN_BEDROCK / AWS_ACCESS_KEY_ID
#   foundry  ← CLAUDE_CODE_USE_FOUNDRY / ANTHROPIC_FOUNDRY_RESOURCE /
#              ANTHROPIC_FOUNDRY_API_KEY
#   api      ← fallback when no bedrock/foundry markers are set but a keys file
#              ($KEYS_GPG) exists (its ANTHROPIC_API_KEY is verified on decrypt)
#   default  ← nothing set and no keys file → no auth override
#
# If several modes' markers are set at once, you're prompted to choose (or, with
# no TTY, the script dies). Set CLAUDE_AUTH_MODE=bedrock|foundry|api to force a
# mode outright, bypassing inference and any prompt (use this in CI).
#
# Note: only *non-secret* markers in $ENV_FILE (e.g. AWS_REGION) are visible to
# inference — secrets living inside the encrypted keys file are not. If a
# bedrock/foundry setup keeps its only distinguishing marker inside the keys
# file, inference can't see it; select the mode with CLAUDE_AUTH_MODE.

set -euo pipefail

# ─── Default CLI params (edit freely) ────────────────────────────────────────
CLAUDE_PARAMS=(
  "--setting-sources" "project,local"
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

# Like load_env_file, but a no-op when the file is missing. Used to expose
# $ENV_FILE's plaintext markers to mode inference without forcing every setup
# (e.g. default or api-only) to have an .env.
load_env_file_soft() {
  [[ -f "$ENV_FILE" ]] && load_env_file "$ENV_FILE"
  return 0
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

# choose_mode <mode>... -> prints the chosen mode on stdout
# Presents a numbered menu of the candidate modes and reads the choice from the
# controlling terminal (mirroring read_secret's /dev/tty preference). With no
# TTY the choice can't be made safely, so it dies and points at CLAUDE_AUTH_MODE.
choose_mode() {
  local modes=("$@") n=$# i reply
  if [[ "$HAVE_TTY" != true ]]; then
    die "Ambiguous auth mode; markers for multiple modes are set (${modes[*]}). Set CLAUDE_AUTH_MODE to one of them."
  fi
  {
    echo "Multiple auth modes detected. Choose one:"
    for i in "${!modes[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${modes[$i]}"; done
  } >&2
  while :; do
    read -r -p "Selection [1-${n}]: " reply < /dev/tty
    [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= n )) && break
    echo "Invalid selection." >&2
  done
  printf '%s' "${modes[$((reply - 1))]}"
}

# Reads KEY=VALUE lines until a blank line/EOF. A key with no value (`KEY=`)
# deletes that key; otherwise later lines override earlier ones (including
# lines from <seed-content>, if given). Prints the merged set, one KEY=VALUE
# per line, sorted. Seed is passed as a string (never a file) so migrated /
# decrypted secrets stay in memory.
prompt_kv() { # prompt_kv [seed-content] -> prints merged KEY=VALUE lines
  local seed="${1:-}"
  local -A kv
  local key val line src
  if [[ -n "$seed" ]]; then
    while IFS='=' read -r key val; do
      [[ -z "$key" || "$key" == \#* ]] && continue
      kv["$key"]="$val"
    done < <(printf '%s\n' "$seed")
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

# ─── Secrets: gpg symmetric, no plaintext on disk, no passphrase cache ──────
# --no-symkey-cache keeps the passphrase out of gpg-agent (the "no caching"
# requirement — a cached passphrase is reachable by same-UID code, exactly the
# threat this feature targets). --pinentry-mode loopback makes --passphrase-fd
# work under any gpg-agent config. Plaintext is only ever passed through a pipe
# or process substitution (anonymous /dev/fd, never a temp file); encryption is
# staged to a sibling temp and atomically renamed, so a mid-write failure can't
# destroy the only encrypted copy.
GPG_COMMON=(--batch --yes --no-symkey-cache --pinentry-mode loopback --passphrase-fd 0)

gpg_encrypt() { # gpg_encrypt <passphrase> <plaintext>  -> writes $KEYS_GPG atomically
  local pass="$1" plain="$2" tmp
  tmp="$(mktemp "${KEYS_GPG}.XXXXXX")" || return 1
  if printf '%s' "$pass" | gpg "${GPG_COMMON[@]}" --symmetric --cipher-algo AES256 \
       --output "$tmp" <(printf '%s' "$plain"); then
    mv -f "$tmp" "$KEYS_GPG"
  else
    rm -f "$tmp"
    return 1
  fi
}

gpg_decrypt() { # gpg_decrypt <passphrase> -> prints decrypted content on stdout
  printf '%s' "$1" | gpg "${GPG_COMMON[@]}" --decrypt "$KEYS_GPG" 2>/dev/null
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
  done < <(printf '%s\n' "$decrypted")
  unset decrypted
}

# Vars whose name suggests a durable secret, auto-detected out of $ENV_FILE
# for migration convenience. Not an allow-list for what the keys file may
# hold — you can type any KEY=VALUE at the keys init/edit prompt regardless
# of name. Covers *TOKEN*/*API_KEY*/*SECRET*/*ACCESS_KEY_ID* so AWS access
# keys and secret keys migrate too, not just the Anthropic key.
SECRET_NAME_PATTERN='^[A-Za-z_]*(TOKEN|API_KEY|SECRET|ACCESS_KEY_ID)[A-Za-z_]*=.+$'

keys_init() {
  [[ -f "$KEYS_GPG" ]] && info "'${KEYS_GPG}' already exists; this will overwrite it."

  local seed="" key
  [[ -f "$ENV_FILE" ]] && seed="$(grep -E "$SECRET_NAME_PATTERN" "$ENV_FILE" 2>/dev/null || true)"

  if [[ -n "$seed" ]]; then
    info "Detected likely secrets in ${ENV_FILE} (will be migrated):"
    while IFS='=' read -r key _; do [[ -n "$key" ]] && info "  ${key}"; done < <(printf '%s\n' "$seed")
  fi
  info "Enter any other secrets as KEY=VALUE (e.g. AWS_ACCESS_KEY_ID=...)."
  info "Blank line/Ctrl-D to finish and encrypt into ${KEYS_GPG}."

  local merged
  merged="$(prompt_kv "$seed")"

  printf '%s\n' "$merged" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=.+$' \
    || die "No secret values provided; aborting keys init."

  local pass
  pass="$(new_passphrase "encrypt")"
  gpg_encrypt "$pass" "$merged" || { unset pass; die "Encryption failed; '${KEYS_GPG}' unchanged."; }
  unset pass

  # Whatever keys ended up in the keys file no longer belong in $ENV_FILE too —
  # the encrypted file is the only on-disk copy. (Note: this scrub overwrites
  # $ENV_FILE in place; it does not securely erase the old plaintext blocks.)
  if [[ -f "$ENV_FILE" ]]; then
    local names pattern scrubbed
    names="$(printf '%s\n' "$merged" | grep -Eo '^[A-Za-z_][A-Za-z0-9_]*=' | sed 's/=$//' | sort -u)"
    if [[ -n "$names" ]]; then
      pattern="$(printf '%s\n' "$names" | paste -sd'|' -)"
      scrubbed="$(grep -Ev "^(${pattern})=" "$ENV_FILE" || true)"
      printf '%s\n' "$scrubbed" > "$ENV_FILE"
    fi
  fi

  info "'${KEYS_GPG}' created. Secret values migrated out of '${ENV_FILE}'."
}

keys_edit() {
  [[ -f "$KEYS_GPG" ]] || die "'${KEYS_GPG}' not found. Run './claude.sh keys init' first."

  local pass current key
  pass="$(read_secret "Passphrase for ${KEYS_GPG}: ")"
  current="$(gpg_decrypt "$pass")" || { unset pass; die "Failed to decrypt '${KEYS_GPG}' (wrong passphrase?)"; }

  info "Current secrets in ${KEYS_GPG}:"
  while IFS='=' read -r key _; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    info "  ${key}"
  done < <(printf '%s\n' "$current")
  info "Type KEY=VALUE to add or replace one, KEY= (empty value) to remove one."
  info "Blank line/Ctrl-D to finish and save; anything untouched is kept as-is."

  local new
  new="$(prompt_kv "$current")"

  printf '%s\n' "$new" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*=.+$' \
    || die "No secrets left; aborting (no changes written)."

  gpg_encrypt "$pass" "$new" || { unset pass; die "Encryption failed; '${KEYS_GPG}' unchanged."; }
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

# ─── Auth mode selection ──────────────────────────────────────────────────────
# Priority: explicit CLAUDE_AUTH_MODE override > inference from markers > api
# fallback (keys file exists) > default (nothing set).
if [[ -n "${CLAUDE_AUTH_MODE:-}" ]]; then
  case "$CLAUDE_AUTH_MODE" in
    bedrock|foundry|api) AUTH_MODE="$CLAUDE_AUTH_MODE" ;;
    *) die "Invalid CLAUDE_AUTH_MODE='${CLAUDE_AUTH_MODE}' (expected bedrock|foundry|api)." ;;
  esac
  info "Auth mode: ${AUTH_MODE} (forced via CLAUDE_AUTH_MODE)"
else
  # Expose $ENV_FILE's plaintext markers to inference (secrets in $KEYS_GPG are
  # intentionally not decrypted here — see the header note).
  load_env_file_soft

  CANDIDATES=()
  if [[ -n "${CLAUDE_CODE_USE_BEDROCK:-}${AWS_REGION:-}${AWS_PROFILE:-}${AWS_BEARER_TOKEN_BEDROCK:-}${AWS_ACCESS_KEY_ID:-}" ]]; then
    CANDIDATES+=("bedrock")
  fi
  if [[ -n "${CLAUDE_CODE_USE_FOUNDRY:-}${ANTHROPIC_FOUNDRY_RESOURCE:-}${ANTHROPIC_FOUNDRY_API_KEY:-}" ]]; then
    CANDIDATES+=("foundry")
  fi
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    CANDIDATES+=("api")
  fi

  if (( ${#CANDIDATES[@]} > 1 )); then
    AUTH_MODE="$(choose_mode "${CANDIDATES[@]}")"
    info "Auth mode: ${AUTH_MODE} (selected from ${CANDIDATES[*]})"
  elif (( ${#CANDIDATES[@]} == 1 )); then
    AUTH_MODE="${CANDIDATES[0]}"
    info "Auth mode: ${AUTH_MODE} (inferred)"
  elif [[ -f "$KEYS_GPG" ]]; then
    AUTH_MODE="api"
    info "Auth mode: api (inferred from ${KEYS_GPG})"
  else
    AUTH_MODE=""
    info "Auth mode: default (no markers set, no keys file)"
  fi
fi

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
    die "Internal error: unexpected auth mode '${AUTH_MODE}'."
    ;;

esac

# -- Set global vars: https://code.claude.com/docs/en/env-vars
export CLAUDE_CONFIG_DIR=./.claude
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1
export CLAUDE_CODE_ENABLE_AUTO_MODE=1

# -- Launch
mkdir -p "$CLAUDE_CONFIG_DIR"
exec claude "${CLAUDE_PARAMS[@]}"
