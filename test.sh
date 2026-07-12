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

# update.sh --full normally fetches install.sh from https://ltm.sh/dev/<ref>;
# for tests, swap that one line for a direct call to the patched local install.sh.
UPDATE_CURL_LINE='curl -fsSL "https://ltm.sh/dev/$REF" | bash -s -- "${ARGS[@]}"'

make_local_update() { # make_local_update <path-to-update.sh> -> patches it in place, prints its path
  local src="$1"
  grep -qF "$UPDATE_CURL_LINE" "$src" \
    || { echo "test.sh: update.sh's curl line has changed — update UPDATE_CURL_LINE in test.sh" >&2; exit 1; }
  # Patched in place (not copied elsewhere): update.sh locates its own repo
  # root via its own path (BASH_SOURCE), so it must stay under .devcontainer/.
  awk -v old="$UPDATE_CURL_LINE" -v install="$INSTALL" '
    $0 == old { print "bash \"" install "\" \"${ARGS[@]}\""; next }
    { print }
  ' "$src" > "$src.tmp"
  mv "$src.tmp" "$src"
  chmod +x "$src"
  printf '%s' "$src"
}

# Surgical update.sh (the default mode) fetches upstream's Dockerfile +
# devcontainer.json via fetch_upstream(); for tests, swap that function's body
# for a `cp` from a local fixture "upstream" .devcontainer/ dir instead.
UPDATE_FETCH_FUNC_START='fetch_upstream() { # fetch_upstream <relative-path-under-.devcontainer> <dest>'

make_local_update_surgical() { # make_local_update_surgical <path-to-update.sh> <upstream-dir> -> patches it in place, prints its path
  local src="$1" upstream_dir="$2"
  grep -qF "$UPDATE_FETCH_FUNC_START" "$src" \
    || { echo "test.sh: update.sh's fetch_upstream() signature has changed — update UPDATE_FETCH_FUNC_START in test.sh" >&2; exit 1; }
  awk -v up="$upstream_dir" '
    /^fetch_upstream\(\) \{/ { print "fetch_upstream() { cp \"" up "/.devcontainer/$1\" \"$2\"; }"; skip=1; next }
    skip && /^}/ { skip=0; next }
    skip { next }
    { print }
  ' "$src" > "$src.tmp"
  mv "$src.tmp" "$src"
  chmod +x "$src"
  printf '%s' "$src"
}

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

test_tool_scaffold() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --tool awscli,azpwsh --force
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG GOLANG=true'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG AWSCLI=true'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG AZPWSH=true'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG AZCLI=false'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG POWERSHELL=false'
}

test_tool_unknown_rejected() {
  local d; d="$(new_dir)"
  if run_install "$d" --tool bogus --force; then
    fail "install.sh should reject an unknown --tool"
  else
    ok "install.sh rejects an unknown --tool"
  fi
}

test_update_script_shipped_and_executable() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --force
  assert_file_exists "$d/.devcontainer/update.sh"
  [ -x "$d/.devcontainer/update.sh" ] && ok "$d/.devcontainer/update.sh is executable" \
    || fail "$d/.devcontainer/update.sh is not executable"
}

test_update_script_full_round_trip() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --tool awscli --force
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG GOLANG=true'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG AWSCLI=true'

  local patched_update
  patched_update="$(make_local_update "$d/.devcontainer/update.sh")"
  if ! ( cd "$d" && bash "$patched_update" --full -- --force ) >/tmp/test.sh.update.log 2>&1; then
    echo "update.sh --full failed (see /tmp/test.sh.update.log):"
    cat /tmp/test.sh.update.log
    fail "update.sh --full ran successfully"
    return
  fi
  ok "update.sh --full ran successfully"

  assert_contains "$d/.devcontainer/Dockerfile" 'ARG GOLANG=true'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG AWSCLI=true'
}

test_update_script_surgical_bumps_and_preserves_edits() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --force --extensions

  # Hand-edit: add a local comment + a local custom line, which must survive.
  sed -i '1i # hand-added local comment' "$d/.devcontainer/Dockerfile"
  echo "# hand-added local line" >> "$d/.devcontainer/Dockerfile"

  # Fixture "upstream": same files, with CLAUDE_VER and the pinned extension bumped.
  local up; up="$(new_dir)"
  mkdir -p "$up/.devcontainer"
  cp "$REPO_ROOT/.devcontainer/Dockerfile" "$up/.devcontainer/Dockerfile"
  cp "$REPO_ROOT/.devcontainer/devcontainer.json" "$up/.devcontainer/devcontainer.json"
  sed -i -E 's/ARG CLAUDE_VER=[0-9.]+/ARG CLAUDE_VER=9.9.999/' "$up/.devcontainer/Dockerfile"
  sed -i -E 's/ms-azuretools\.vscode-containers@[0-9.]+/ms-azuretools.vscode-containers@9.9.9/' "$up/.devcontainer/devcontainer.json"

  local patched_update
  patched_update="$(make_local_update_surgical "$d/.devcontainer/update.sh" "$up")"
  if ! ( cd "$d" && bash "$patched_update" ) >/tmp/test.sh.surgical.log 2>&1; then
    echo "surgical update.sh failed (see /tmp/test.sh.surgical.log):"
    cat /tmp/test.sh.surgical.log
    fail "surgical update.sh ran successfully"
    return
  fi
  ok "surgical update.sh ran successfully"

  assert_contains "$d/.devcontainer/Dockerfile" 'ARG CLAUDE_VER=9.9.999'
  assert_contains "$d/.devcontainer/devcontainer.json" 'ms-azuretools.vscode-containers@9.9.9'
  assert_contains "$d/.devcontainer/Dockerfile" '# hand-added local comment'
  assert_contains "$d/.devcontainer/Dockerfile" '# hand-added local line'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG GOLANG=true'
  assert_contains "$d/.devcontainer/Dockerfile" 'ARG PYTHON=false'
}

test_update_script_surgical_skip_summary() {
  local d; d="$(new_dir)"
  run_install "$d" --language go --force

  # Fixture "upstream": drop the GOPLS_VER pin entirely (-> local-only from
  # this repo's perspective) and add a brand-new pin (-> upstream-only).
  local up; up="$(new_dir)"
  mkdir -p "$up/.devcontainer"
  cp "$REPO_ROOT/.devcontainer/Dockerfile" "$up/.devcontainer/Dockerfile"
  cp "$REPO_ROOT/.devcontainer/devcontainer.json" "$up/.devcontainer/devcontainer.json"
  awk '/# renovate:.*depName=golang\.org\/x\/tools\/gopls/ { getline; next } { print }' \
    "$up/.devcontainer/Dockerfile" > "$up/.devcontainer/Dockerfile.tmp"
  mv "$up/.devcontainer/Dockerfile.tmp" "$up/.devcontainer/Dockerfile"
  {
    echo '# renovate: datasource=npm depName=totally-new-pkg'
    echo 'ARG TOTALLY_NEW_VER=1.0.0'
  } >> "$up/.devcontainer/Dockerfile"

  local patched_update out
  patched_update="$(make_local_update_surgical "$d/.devcontainer/update.sh" "$up")"
  if ! out="$(cd "$d" && bash "$patched_update" 2>&1)"; then
    echo "$out"
    fail "surgical update.sh (skip summary) ran successfully"
    return
  fi
  ok "surgical update.sh (skip summary) ran successfully"

  assert_contains <(printf '%s' "$out") "skipped (local-only, no matching upstream key): ARG GOPLS_VER"
  assert_contains <(printf '%s' "$out") "skipped (upstream-only, run --full to adopt): ARG TOTALLY_NEW_VER"
}

test_update_script_help_mentions_full_and_repo() {
  local out
  out="$(bash "$REPO_ROOT/.devcontainer/update.sh" --help)"
  assert_contains <(printf '%s' "$out") "--full"
  assert_contains <(printf '%s' "$out") "--repo <o/r>"
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
  local dedicated=" NVM_URL "

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

  # GO_VER used to be GO_URL (version embedded in an amd64-only download URL,
  # handled by its own dedicated customManager). Assert it's now a plain,
  # arch-independent ARG covered by the general alternation above, not still
  # a dedicated URL-based manager.
  if grep -qP '^ARG GO_VER=\S+$' "$dockerfile" && echo "$alternation" | tr '|' '\n' | grep -qxF "GO_VER"; then
    ok "GO_VER is a plain ARG covered by the renovate.json5 alternation (not a dedicated URL manager)"
  else
    fail "GO_VER is not a plain Renovate-covered ARG in renovate.json5"
  fi
}

test_renovate_regex_covers_extension_pins() {
  local renovate="$REPO_ROOT/renovate.json5"
  # Pull the extension customManager's matchStrings regex out of the JSON5
  # source (a single-quoted string, one JSON5 backslash-escape level) and
  # unescape it once so it can be used as a plain -P regex below.
  local line regex
  line="$(grep -n 'depName>\[' "$renovate" | cut -d: -f1)"
  [ -n "$line" ] || { fail "renovate.json5: couldn't locate the extension pin matchStrings line"; return; }
  regex="$(sed -n "${line}p" "$renovate" | sed -E "s/^ *'(.*)',?\$/\1/")"
  regex="${regex//\\\\/\\}"

  local missing=0
  for f in "$REPO_ROOT"/templates/*/extensions.json "$REPO_ROOT"/.devcontainer/devcontainer.json; do
    [ -f "$f" ] || continue
    while IFS= read -r pin; do
      [ -z "$pin" ] && continue
      if echo "$pin" | grep -qP "$regex"; then
        ok "renovate.json5 extension regex matches '$pin' in $(basename "$f")"
      else
        fail "renovate.json5 extension regex misses '$pin' in $f"
        missing=$((missing+1))
      fi
    done < <(grep -oP '"[\w-]+\.[\w-]+@[^"]+"' "$f")
  done
  [ "$missing" -eq 0 ] && ok "no pinned extensions are unmatched by the renovate.json5 custom manager"
}

test_extensions_no_duplicate_canonical() {
  # A pinned "publisher.name@version" and an unpinned "publisher.name" of the
  # same extension would both survive install.sh's `unique` dedup as distinct
  # strings — guard against that ever happening across base + templates.
  local seen=""
  local dup=0
  while IFS= read -r ext; do
    [ -z "$ext" ] && continue
    local canonical="${ext%@*}"
    case "$seen" in
      *" $canonical "*) fail "'$canonical' appears in more than one canonical form across extensions sources"; dup=$((dup+1)) ;;
      *) seen="$seen $canonical " ;;
    esac
  done < <(jq -r '.customizations.vscode.extensions[]' "$REPO_ROOT/.devcontainer/devcontainer.json"; jq -r '.[]' "$REPO_ROOT"/templates/*/extensions.json)
  [ "$dup" -eq 0 ] && ok "every extension appears in exactly one canonical form"
}

test_token_set_matches_dockerfile_args() {
  # install.sh's --language/--tool tokens must cover every ARG the Dockerfile
  # can toggle 1:1, or update.sh's ARG->token round-trip silently drops a
  # feature (e.g. a hand-added CLI ARG with no corresponding flag).
  local dockerfile="$REPO_ROOT/.devcontainer/Dockerfile"
  local install="$REPO_ROOT/install.sh"

  # Toggleable feature ARGs (default false). CLAUDECODE defaults true and
  # isn't a --language/--tool selector.
  local dockerfile_args
  dockerfile_args="$(grep -oP '(?<=^ARG )[A-Z_]+(?==false)' "$dockerfile" | sort -u)"

  # ARGs install.sh's lang_arg()/tool_arg() can produce.
  local mapped_args
  mapped_args="$(sed -n '/^lang_arg()/,/^}/p; /^tool_arg()/,/^}/p' "$install" \
    | grep -oP '(?<=echo ")[A-Z_]+(?=")' | sort -u)"

  local missing=0
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    if echo "$mapped_args" | grep -qxF "$a"; then
      ok "install.sh has a --language/--tool token for Dockerfile ARG $a"
    else
      fail "Dockerfile ARG $a has no --language/--tool token (update.sh round-trip would drop it)"
      missing=$((missing+1))
    fi
  done <<< "$dockerfile_args"

  while IFS= read -r a; do
    [ -z "$a" ] && continue
    echo "$dockerfile_args" | grep -qxF "$a" \
      || { fail "install.sh maps a token to ARG $a, but the Dockerfile has no 'ARG $a=false'"; missing=$((missing+1)); }
  done <<< "$mapped_args"

  [ "$missing" -eq 0 ] && ok "--language/--tool token set exactly matches flippable Dockerfile ARGs"
}

test_ask_yn_all_sticks_across_subshell() {
  # Regression: the yes-to-all / no-to-all choice used to be stored in a shell
  # variable assigned inside "$(ask_yn ...)" — a command-substitution subshell —
  # so it evaporated on subshell exit and every overwrite still prompted. It's
  # now file-backed; verify a choice made in one "$(ask_yn ...)" call is honored
  # by later calls. Runs the REAL ask_yn extracted from install.sh so the test
  # tracks the shipped code, with a stub tty reader in place of the prompt.
  local harness
  harness="$(awk '/^ask_yn\(\) \{/,/^\}/' "$REPO_ROOT/install.sh")"

  drive() { # drive <first-answer>  -> echoes three consecutive ask_yn results
    local first="$1"
    (
      eval "$harness"
      FORCE=false
      HAVE_TTY=true
      ANSWER_ALL_FILE="$(mktemp)"
      local calls; calls="$(mktemp)"; echo 0 > "$calls"
      # First prompt returns $first (a=yes-to-all / o=no-to-all); if stickiness
      # is broken, ask_yn calls this again and gets a plain "n"/"y" that differs.
      ask() {
        local n; n="$(cat "$calls")"; echo $((n+1)) > "$calls"
        [ "$n" -eq 0 ] && printf '%s' "$first" || printf 'n'
      }
      printf '%s %s %s' "$(ask_yn q1)" "$(ask_yn q2)" "$(ask_yn q3)"
      rm -f "$ANSWER_ALL_FILE" "$calls"
    )
  }

  assert_eq "$(drive a)" "yes yes yes" "yes-to-all sticks across ask_yn subshells"
  assert_eq "$(drive o)" "no no no"    "no-to-all sticks across ask_yn subshells"
  unset -f drive
}

test_empty_array_expansions_guarded() {
  # macOS's default /bin/bash is 3.2, where `set -u` (which these scripts enable)
  # turns expansion of an EMPTY array — "${arr[@]}" — into a fatal "unbound
  # variable" error. Bash 4.4+ (what CI runs) silently tolerates it, so this
  # regression can't be reproduced by running the scripts here — guard it
  # statically instead. Arrays declared empty with `NAME=()` can still be empty
  # at use (blank language prompt, no --tool, no `-- <args>`), so EVERY
  # "${NAME[@]}" expansion — for-loop, append, or command args — must use the
  # ${NAME[@]+"${NAME[@]}"} guard, which expands to nothing when empty.
  local scripts=("$REPO_ROOT/install.sh" "$REPO_ROOT/.devcontainer/update.sh")
  local bad=0 f names name hits
  for f in "${scripts[@]}"; do
    names="$(grep -oE '^[[:space:]]*[A-Za-z_]+=\(\)' "$f" | sed -E 's/^[[:space:]]*//; s/=\(\)//')"
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      # Flag a bare "${NAME[@]}" NOT preceded by '+'. The guarded form
      # ${NAME[@]+"${NAME[@]}"} contains its own "${NAME[@]}" but preceded by
      # '+', so it's excluded; ${#NAME[@]}, ${NAME[*]} and ${NAME[@]:-} never match.
      hits="$(grep -nE "[^+]\"\\\$\\{${name}\\[@\\]\\}\"" "$f" || true)"
      if [ -n "$hits" ]; then
        fail "$(basename "$f"): bare \"\${$name[@]}\" crashes on bash 3.2 — use \${$name[@]+\"\${$name[@]}\"}: $hits"
        bad=$((bad+1))
      fi
    done <<< "$names"
  done
  [ "$bad" -eq 0 ] && ok "all empty-capable array expansions use the bash-3.2 nounset guard"
}

test_no_pcre_grep_in_shipped_scripts() {
  # `grep -P` (PCRE) is a GNU extension the BSD grep on macOS lacks — a script
  # shipped into generated repos that relies on it dies with "invalid option
  # -- P" on a Mac. test.sh itself is dev/CI-only (Linux), so it's exempt.
  local shipped=("$REPO_ROOT/install.sh" "$REPO_ROOT/.devcontainer/update.sh" "$REPO_ROOT/claude.sh")
  local bad=0 f hits
  for f in "${shipped[@]}"; do
    [ -f "$f" ] || continue
    # Ignore comment-only lines so a doc reference to grep -P isn't a false hit.
    hits="$(grep -nE 'grep +-[a-zA-Z]*P' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    if [ -n "$hits" ]; then
      fail "$(basename "$f"): uses non-portable 'grep -P' (fails on macOS BSD grep): $hits"
      bad=$((bad+1))
    fi
  done
  [ "$bad" -eq 0 ] && ok "no shipped script relies on GNU-only 'grep -P'"
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
  test_tool_scaffold
  test_tool_unknown_rejected
  test_verbatim_extras
  test_extensions_default_off
  test_extensions_opt_in
  test_extensions_no_duplicate_canonical
  test_idempotent_skip
  test_ask_yn_all_sticks_across_subshell
  test_empty_array_expansions_guarded
  test_no_pcre_grep_in_shipped_scripts
  test_gitignore_merge
  test_gitignore_secrets
  test_settings_merge_notty_keeps_existing
  test_settings_merge_force_takes_generated
  test_keys_init_migrates_and_encrypts
  test_keys_init_no_plaintext_on_gpg_failure
  test_keys_edit_no_plaintext_on_gpg_failure
  test_api_mode_decrypts_keys
  test_update_script_shipped_and_executable
  test_update_script_full_round_trip
  test_update_script_surgical_bumps_and_preserves_edits
  test_update_script_surgical_skip_summary
  test_update_script_help_mentions_full_and_repo
  test_shellcheck
  test_renovate_regex_covers_pins
  test_renovate_regex_covers_extension_pins
  test_token_set_matches_dockerfile_args
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
