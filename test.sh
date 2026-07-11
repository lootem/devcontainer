#!/usr/bin/env bash
#
# test.sh — exercise install.sh against the *working tree* (uncommitted changes
# included), without needing to push to a branch first.
#
# install.sh always `git clone`s --repo from GitHub. To test local changes, this
# script builds a scratch copy of install.sh with that clone step replaced by a
# local `cp` of this repo, then runs a series of scaffold scenarios against temp
# targets and asserts on the generated output.
#
# Usage: ./test.sh [--keep] [-k <substring>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEEP=false
FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=true; shift ;;
    -k)     FILTER="$2"; shift 2 ;;
    -k=*)   FILTER="${1#*=}"; shift ;;
    *)      echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

FAILS=0
SCRATCH_DIRS=()

cleanup() {
  if [ "$KEEP" = true ]; then
    [ ${#SCRATCH_DIRS[@]} -gt 0 ] && { echo; echo "Kept scratch dirs:"; printf '  %s\n' "${SCRATCH_DIRS[@]}"; }
    return
  fi
  for d in "${SCRATCH_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

new_dir() { # new_dir -> prints a fresh scratch dir, tracked for cleanup
  local d
  d="$(mktemp -d)"
  SCRATCH_DIRS+=("$d")
  printf '%s' "$d"
}

# --- Local-clone bypass ----------------------------------------------------------
CLONE_LINE='git clone --depth 1 --branch "$REF" "https://github.com/$REPO" "$SRC" >/dev/null 2>&1 \'
CLONE_LINE2='  || die "Failed to clone https://github.com/$REPO@$REF"'

make_local_install() { # make_local_install -> prints path to a patched install.sh
  local patched="$PATCH_DIR/install.sh"
  grep -qF "$CLONE_LINE" "$REPO_ROOT/install.sh" \
    || { echo "test.sh: install.sh's git clone line has changed — update CLONE_LINE in test.sh" >&2; exit 1; }
  awk -v old1="$CLONE_LINE" -v old2="$CLONE_LINE2" -v root="$REPO_ROOT" '
    $0 == old1 { getline nextline; if (nextline == old2) { print "cp -r \"" root "/.\" \"$SRC\" >/dev/null 2>&1 || die \"local copy failed\""; next } }
    { print }
  ' "$REPO_ROOT/install.sh" > "$patched"
  chmod +x "$patched"
  printf '%s' "$patched"
}

PATCH_DIR="$(mktemp -d)"
SCRATCH_DIRS+=("$PATCH_DIR")
INSTALL="$(make_local_install)"

run_install() { # run_install <target> <args...>  -> runs patched install.sh non-interactively
  local target="$1"; shift
  bash "$INSTALL" --target "$target" "$@" </dev/null >/tmp/test.sh.last.log 2>&1 \
    || { echo "install.sh failed (see /tmp/test.sh.last.log):"; cat /tmp/test.sh.last.log; return 1; }
}

# --- Assertion helpers ------------------------------------------------------------
CURRENT_TEST=""
CURRENT_TEST_FAILED=false

ok()   { echo "  ok   - $1"; }
fail() { echo "  FAIL - $1"; CURRENT_TEST_FAILED=true; FAILS=$((FAILS+1)); }

assert_file_exists() { # assert_file_exists <path>
  [ -f "$1" ] && ok "$1 exists" || fail "$1 missing"
}

assert_file_not_exists() { # assert_file_not_exists <path>
  [ -f "$1" ] && fail "$1 exists (should not)" || ok "$1 absent"
}

assert_json_valid() { # assert_json_valid <path>
  jq . "$1" >/dev/null 2>&1 && ok "$1 is valid JSON" || fail "$1 is not valid JSON"
}

assert_json_has() { # assert_json_has <path> <jq-filter> <description>
  local path="$1" filter="$2" desc="${3:-$2}"
  if [ "$(jq -r "($filter) // false" "$path" 2>/dev/null)" = "true" ]; then
    ok "$path: $desc"
  else
    fail "$path: $desc"
  fi
}

assert_json_missing() { # assert_json_missing <path> <jq-filter> <description>
  local path="$1" filter="$2" desc="${3:-$2}"
  if [ "$(jq -r "($filter) // false" "$path" 2>/dev/null)" = "false" ]; then
    ok "$path: $desc"
  else
    fail "$path: $desc"
  fi
}

assert_contains() { # assert_contains <path> <literal>
  grep -qF -- "$2" "$1" 2>/dev/null && ok "$1 contains '$2'" || fail "$1 missing '$2'"
}

assert_count() { # assert_count <path> <exact-line> <expected-n>
  local n
  n="$(grep -cxF -- "$2" "$1" 2>/dev/null || true)"
  [ "$n" = "$3" ] && ok "$1 has line '$2' exactly $3 time(s)" || fail "$1 has line '$2' $n time(s), expected $3"
}

assert_eq() { # assert_eq <actual> <expected> <description>
  [ "$1" = "$2" ] && ok "$3" || fail "$3 (got '$1', expected '$2')"
}

# --- Test cases ---------------------------------------------------------------

test_syntax() {
  bash -n "$REPO_ROOT/install.sh" && ok "install.sh parses" || fail "install.sh syntax error"
  bash -n "$REPO_ROOT/claude.sh" && ok "claude.sh parses" || fail "claude.sh syntax error"
}

test_fresh_scaffold() {
  local d; d="$(new_dir)"
  run_install "$d" --language go,js --force
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG GOLANG=true'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG NODEJS=true'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG PYTHON=false'
  assert_json_valid "$d/.vscode/settings.json"
  assert_json_valid "$d/.devcontainer/devcontainer.json"
  assert_contains "$d/.gitignore" 'node_modules'
  assert_contains "$d/.gitignore" 'go.work'
}

test_extensions_default_off() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --force
  assert_json_missing "$d/.devcontainer/devcontainer.json" '.customizations.vscode | has("extensions")' "extensions key absent by default"
}

test_extensions_opt_in() {
  local d; d="$(new_dir)"
  run_install "$d" --language go,js --force --extensions
  assert_json_has "$d/.devcontainer/devcontainer.json" '.customizations.vscode | has("extensions")' "extensions key present"
  local len uniq
  len="$(jq '.customizations.vscode.extensions | length' "$d/.devcontainer/devcontainer.json")"
  uniq="$(jq '.customizations.vscode.extensions | unique | length' "$d/.devcontainer/devcontainer.json")"
  [ "$len" -gt 0 ] && ok "extensions array non-empty ($len)" || fail "extensions array empty"
  assert_eq "$len" "$uniq" "extensions array is deduped"
}

test_idempotent_skip() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --force
  local before after
  before="$(md5sum "$d/.devcontainer/Dockerfile" | cut -d' ' -f1)"
  run_install "$d" --language go
  after="$(md5sum "$d/.devcontainer/Dockerfile" | cut -d' ' -f1)"
  assert_eq "$after" "$before" "Dockerfile untouched on no-force rerun"
}

test_dotnet_scaffold() {
  local d; d="$(new_dir)"
  run_install "$d" --language dotnet --force
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG DOTNET=true'
  assert_json_valid "$d/.vscode/settings.json"
  assert_json_valid "$d/.devcontainer/devcontainer.json"
  assert_contains "$d/.gitignore" '[Bb]in/'
}

test_verbatim_extras() {
  local d; d="$(new_dir)"
  run_install "$d" --language python,js --force
  assert_file_exists "$d/.vscode/launch.json"
  assert_file_exists "$d/pnpm-workspace.yaml"
}

test_gitignore_secrets() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --force
  assert_contains "$d/.gitignore" ".env.keys"
  assert_contains "$d/.gitignore" ".env.keys.gpg"
}

test_keys_init_migrates_and_encrypts() {
  local d; d="$(new_dir)"
  cp "$REPO_ROOT/claude.sh" "$d/claude.sh"
  chmod +x "$d/claude.sh"
  echo "ANTHROPIC_API_KEY=sk-test-abc" > "$d/.env"

  # Auto-detected ANTHROPIC_API_KEY needs no retyping; type AWS_ACCESS_KEY_ID
  # by hand (its name doesn't match the TOKEN/API_KEY auto-detect pattern),
  # blank line to finish, then passphrase twice.
  if ! ( cd "$d" && printf 'AWS_ACCESS_KEY_ID=AKIA123\n\ntestpass\ntestpass\n' | ./claude.sh keys init ) \
      >/tmp/test.sh.keys_init.log 2>&1; then
    fail "claude.sh keys init failed (see /tmp/test.sh.keys_init.log)"
    cat /tmp/test.sh.keys_init.log
    return
  fi

  assert_file_exists "$d/.env.keys.gpg"
  assert_file_not_exists "$d/.env.keys"
  if grep -q '^ANTHROPIC_API_KEY=' "$d/.env" 2>/dev/null; then
    fail "$d/.env still contains ANTHROPIC_API_KEY (secret not migrated out)"
  else
    ok "$d/.env no longer contains ANTHROPIC_API_KEY"
  fi

  local decrypted
  decrypted="$(cd "$d" && printf 'testpass\n' | gpg --batch --yes --passphrase-fd 0 --decrypt .env.keys.gpg 2>/dev/null)"
  assert_contains <(printf '%s' "$decrypted") "AWS_ACCESS_KEY_ID=AKIA123"
}

test_keys_init_no_plaintext_on_gpg_failure() {
  local d; d="$(new_dir)"
  local tmpdir; tmpdir="$(new_dir)"
  cp "$REPO_ROOT/claude.sh" "$d/claude.sh"
  chmod +x "$d/claude.sh"
  mkdir -p "$d/readonly"
  chmod 500 "$d/readonly"

  if ( cd "$d" && TMPDIR="$tmpdir" KEYS_GPG="$d/readonly/.env.keys.gpg" \
       bash -c "printf 'ANTHROPIC_API_KEY=sk-x\n\ntestpass\ntestpass\n' | ./claude.sh keys init" ) \
      >/tmp/test.sh.keys_init_gpgfail.log 2>&1; then
    fail "claude.sh keys init should fail when gpg can't write its output"
  else
    ok "claude.sh keys init fails cleanly when gpg can't write its output"
  fi
  chmod 700 "$d/readonly"

  assert_file_not_exists "$d/readonly/.env.keys.gpg"
  if [ -z "$(ls -A "$tmpdir" 2>/dev/null)" ]; then
    ok "no leftover plaintext temp files after gpg failure"
  else
    fail "leftover temp files after gpg failure: $(ls -A "$tmpdir")"
  fi
}

test_keys_edit_no_plaintext_on_gpg_failure() {
  local d; d="$(new_dir)"
  local tmpdir; tmpdir="$(new_dir)"
  cp "$REPO_ROOT/claude.sh" "$d/claude.sh"
  chmod +x "$d/claude.sh"
  mkdir -p "$d/keys"
  echo "ANTHROPIC_API_KEY=sk-test-abc" > "$d/.env"
  ( cd "$d" && KEYS_GPG="$d/keys/.env.keys.gpg" \
    bash -c "printf '\ntestpass\ntestpass\n' | ./claude.sh keys init" ) >/dev/null 2>&1

  # Read-only *directory* (not the file): gpg can still decrypt the existing
  # keys file (r-x traversal), but the atomic re-encrypt can't create its temp
  # in that dir, so the write fails and the original file must survive. (A
  # read-only file alone wouldn't test this: the temp+rename write replaces the
  # directory entry, which a writable dir permits regardless of file mode.)
  chmod 500 "$d/keys"
  if ( cd "$d" && TMPDIR="$tmpdir" KEYS_GPG="$d/keys/.env.keys.gpg" \
       bash -c "printf 'testpass\nANTHROPIC_API_KEY=sk-changed\n\n' | ./claude.sh keys edit" ) \
      >/tmp/test.sh.keys_edit_gpgfail.log 2>&1; then
    fail "claude.sh keys edit should fail when gpg can't write its output"
  else
    ok "claude.sh keys edit fails cleanly when gpg can't write its output"
  fi
  chmod 700 "$d/keys"

  if [ -z "$(ls -A "$tmpdir" 2>/dev/null)" ]; then
    ok "no leftover plaintext temp files after gpg failure"
  else
    fail "leftover temp files after gpg failure: $(ls -A "$tmpdir")"
  fi

  local decrypted
  decrypted="$(printf 'testpass\n' | gpg --batch --yes --passphrase-fd 0 --decrypt "$d/keys/.env.keys.gpg" 2>/dev/null)"
  assert_contains <(printf '%s' "$decrypted") "ANTHROPIC_API_KEY=sk-test-abc"
}

test_api_mode_decrypts_keys() {
  local d; d="$(new_dir)"
  cp "$REPO_ROOT/claude.sh" "$d/claude.sh"
  chmod +x "$d/claude.sh"
  mkdir -p "$d/bin"
  cat > "$d/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
EOF
  chmod +x "$d/bin/claude"
  echo "ANTHROPIC_API_KEY=sk-test-xyz" > "$d/.env"
  ( cd "$d" && printf '\ntestpass\ntestpass\n' | ./claude.sh keys init ) >/dev/null 2>&1

  ( cd "$d" && printf 'testpass\n' | PATH="$d/bin:$PATH" ./claude.sh api ) \
    >/tmp/test.sh.api_mode.log 2>&1
  assert_contains /tmp/test.sh.api_mode.log "ANTHROPIC_API_KEY=sk-test-xyz"
}

test_renovate_regex_covers_pins() {
  local dockerfile="$REPO_ROOT/.devcontainer/Dockerfile"
  local renovate="$REPO_ROOT/renovate.json5"

  # ARGs covered by the primary bare-ARG customManager's name alternation.
  local alternation
  alternation="$(grep -oP '(?<=\(\?:)[A-Z_|]+(?=\)=)' "$renovate")"

  # ARGs handled by their own dedicated customManagers (version embedded in a URL).
  local dedicated=" GO_URL NVM_URL "

  local missing=0
  while IFS= read -r arg_name; do
    [ -z "$arg_name" ] && continue
    case "$dedicated" in
      *" $arg_name "*) continue ;;
    esac
    if echo "$alternation" | tr '|' '\n' | grep -qxF "$arg_name"; then
      ok "renovate.json5 alternation covers ARG $arg_name"
    else
      fail "renovate.json5 alternation missing ARG $arg_name (has a # renovate: comment in Dockerfile but isn't matched)"
      missing=$((missing+1))
    fi
  done < <(grep -A1 '# renovate:' "$dockerfile" | grep -oP '(?<=^ARG )[A-Z_]+(?==)')

  [ "$missing" -eq 0 ] && ok "no renovate-commented ARGs are unmatched"
}

test_shellcheck() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  skip - shellcheck not installed"
    return
  fi
  shellcheck "$REPO_ROOT/install.sh" "$REPO_ROOT/claude.sh" "$REPO_ROOT/test.sh" \
    && ok "shellcheck clean" || fail "shellcheck reported issues"
}

test_gitignore_merge() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --force
  echo "my_custom_ignore/" >> "$d/.gitignore"
  run_install "$d" --language go
  assert_contains "$d/.gitignore" "my_custom_ignore/"
  assert_count "$d/.gitignore" "go.work" 1
}

test_settings_merge_notty_keeps_existing() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --force
  jq '. + {"my.custom.key": true, "editor.wordWrap": "off"}' "$d/.vscode/settings.json" > "$d/.vscode/settings.json.tmp"
  mv "$d/.vscode/settings.json.tmp" "$d/.vscode/settings.json"
  run_install "$d" --language go
  assert_json_has "$d/.vscode/settings.json" '.["my.custom.key"] == true' "custom key preserved"
  assert_json_has "$d/.vscode/settings.json" '.["editor.wordWrap"] == "off"' "conflicting key kept as existing (no tty)"
}

test_settings_merge_force_takes_generated() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --force
  jq '. + {"my.custom.key": true, "editor.wordWrap": "off"}' "$d/.vscode/settings.json" > "$d/.vscode/settings.json.tmp"
  mv "$d/.vscode/settings.json.tmp" "$d/.vscode/settings.json"
  run_install "$d" --language go
  run_install "$d" --language go --force
  assert_json_has "$d/.vscode/settings.json" '.["editor.wordWrap"] == "on"' "conflicting key reverts to generated with --force"
  assert_json_has "$d/.vscode/settings.json" '.["my.custom.key"] == true' "custom key still preserved after --force"
}

# --- Runner ------------------------------------------------------------------

TESTS=(
  test_syntax
  test_fresh_scaffold
  test_dotnet_scaffold
  test_verbatim_extras
  test_extensions_default_off
  test_extensions_opt_in
  test_idempotent_skip
  test_gitignore_merge
  test_gitignore_secrets
  test_settings_merge_notty_keeps_existing
  test_settings_merge_force_takes_generated
  test_keys_init_migrates_and_encrypts
  test_keys_init_no_plaintext_on_gpg_failure
  test_keys_edit_no_plaintext_on_gpg_failure
  test_api_mode_decrypts_keys
  test_shellcheck
  test_renovate_regex_covers_pins
)

SUITE_FAILS=0
for t in "${TESTS[@]}"; do
  if [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]]; then
    continue
  fi
  echo "=== $t ==="
  CURRENT_TEST_FAILED=false
  "$t"
  if [ "$CURRENT_TEST_FAILED" = true ]; then
    echo "FAIL: $t"
    SUITE_FAILS=$((SUITE_FAILS+1))
  else
    echo "PASS: $t"
  fi
  echo
done

echo "-----------------------------------"
if [ "$SUITE_FAILS" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$SUITE_FAILS test(s) failed."
  exit 1
fi
