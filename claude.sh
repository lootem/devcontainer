#!/usr/bin/env bash
# claude.sh
# Usage: ./claude.sh [bedrock|foundry|api]
#        No argument → runs with default CLI params only.

set -euo pipefail

# ─── Default CLI params (edit freely) ────────────────────────────────────────
CLAUDE_PARAMS=(
  "--setting-sources" "project"
  "--effort" "medium"
  # "--model" "claude-sonnet-4-5"
)

# Path to your .env file (used only in api mode)
ENV_FILE="${ENV_FILE:-.env}"

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

# ─── Auth mode ────────────────────────────────────────────────────────────────
AUTH_MODE="${1:-}"

case "$AUTH_MODE" in

  bedrock)
    info "Mode: AWS Bedrock"
    load_env_file "$ENV_FILE"

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
      die "No Bedrock credentials found in '${ENV_FILE}'. Set AWS_BEARER_TOKEN_BEDROCK, AWS_PROFILE, or AWS_ACCESS_KEY_ID."
    fi

    CLAUDE_PARAMS+=("--bedrock")
    ;;

  foundry)
    info "Mode: Azure AI Foundry"
    load_env_file "$ENV_FILE"

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
    info "Mode: Anthropic API  (key from ${ENV_FILE})"
    load_env_file "$ENV_FILE"
    [[ -n "${ANTHROPIC_API_KEY:-}" ]] \
      || die "ANTHROPIC_API_KEY not found in '${ENV_FILE}'"
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
