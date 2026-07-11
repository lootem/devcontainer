# AGENTS.md

## What this project is

A **dev container scaffolding template**. It is not an application — it is a
repository that gets *stamped out* into other repositories. A user runs one
command (`curl -fsSL https://ltm.sh/dev | bash`, or `./install.sh` from a
clone), picks one or more languages, and gets a ready-to-open VS Code Dev
Container plus editor config, `.gitignore`, and a preconfigured Claude Code
setup.

The "product" is the generator script (`install.sh`) plus the template inputs
it assembles (`.devcontainer/` + `templates/`).

**Meta note:** you (the agent) are running inside this repo's own dev
container, built from its own `.devcontainer/Dockerfile`. Editing the
Dockerfile/`devcontainer.json` won't change your current environment until the
user rebuilds the container — verify those edits by inspection/`docker build`,
not by trying them live. `.claude/` here is this container's own live Claude
state, not a template to copy (that's `skills/`).

## Layout

| Path | Role |
| --- | --- |
| `install.sh` | The scaffolder. Clones this repo, takes `.devcontainer/` as a baseline, and merges in `templates/<lang>/` for each selected language. All feature logic lives here. |
| `test.sh` | Verification harness for `install.sh` — see "Testing / verifying changes" below. |
| `claude.sh` | Launcher copied into every generated project. Picks a Claude backend (`api`/`bedrock`/`foundry`) and `exec claude`. Points `CLAUDE_CONFIG_DIR` at `./.claude` so state survives container rebuilds. |
| `.devcontainer/` | The baseline container. `Dockerfile` (feature-flagged via `ARG`s), `docker-compose.yml`, `devcontainer.json`, `awscli.pub`. |
| `templates/` | Per-language fragments merged into the baseline. `templates/basesettings.json` and `templates/basegitignore` are the always-included base; `templates/<lang>/` holds that language's extras. |
| `skills/` | Curated Claude Code skills, optionally copied into a project's `.claude/skills/` with `--skills`. |
| `README.md` | User-facing docs. |

`.claude/` is local state (settings, history, skills) — untracked scaffolding
output, not source. Don't treat files under it as project code.

## How the generator assembles a project

`install.sh` builds each output file by a specific strategy (see the
`═══ Assembly ═══` section of the script):

- **Dockerfile** — copied, then each selected language's `ARG <NAME>=false` is
  flipped to `true` via `sed`. The `ARG`↔language mapping is `lang_arg()`
  (`python→PYTHON`, `go→GOLANG`, `js→NODEJS`).
- **devcontainer.json** — baseline's extensions merged with each
  `templates/<lang>/extensions.json`, deduped with `jq ... | unique`, but only
  when extensions were requested (see "Recommended extensions are opt-in"
  below). Otherwise the `customizations.vscode.extensions` key is dropped.
- **.vscode/settings.json** — `templates/basesettings.json` deep-merged with each
  `templates/<lang>/settings.json` (`jq -s 'reduce .[] as $o ({}; . * $o)'`).
  Template settings are JSONC; `strip_jsonc()` removes comments/trailing commas
  first. The result is combined with any existing target file via
  `merge_settings_json()` — see "Merging into existing files" below.
- **.gitignore** — `templates/basegitignore` concatenated with each language's
  `*gitignore` file, then combined with any existing target file via
  `merge_gitignore()`.
- **Per-language extra files** — copied verbatim by a `case` in the script
  (e.g. python's `launch.json`, js's `pnpm-workspace.yaml`).
- **Root helpers** — `claude.sh` and `.env.example` always copied.

Whole-file writes (Dockerfile, devcontainer.json, docker-compose.yml,
per-language extras, skills) go through `may_write()` (respects `--force` /
interactive overwrite prompt / no-tty skip). Prompts read from `/dev/tty` so
they work when the script is piped into `bash`.

### Recommended extensions are opt-in
`--extensions` (default off, prompted interactively like `--skills`) controls
whether `customizations.vscode.extensions` is populated in the generated
devcontainer.json. When off, the key is deleted entirely (`jq
'del(.customizations.vscode.extensions)'`) rather than merged — no VS Code
extensions get recommended unless the user opts in.

### Merging into existing files
Re-running the generator against a target that already has a `.gitignore` or
`.vscode/settings.json` does **not** clobber them (unlike the `may_write()`
whole-file overwrite prompt used elsewhere):
- `merge_gitignore()` appends only the generated lines not already present
  (exact line match) under a `# --- merged from generator ---` marker. Existing
  content is never touched or reordered.
- `merge_settings_json()` adds any generated key missing from the existing
  file with no prompt, silently keeps a key whose existing value already
  matches the generated one, and for a true value conflict prompts per-key via
  `ask_yn()` (existing value is kept unless the user says yes).

### The `ask_yn()` prompt helper
All yes/no prompts (`may_write()`'s overwrite prompt, `merge_settings_json()`'s
per-key conflict prompt) go through `ask_yn()`, which supports a sticky
"yes to all" / "no to all" answer (`a`/`o`) so the user isn't asked the same
question once per file or once per settings key. `--force` short-circuits
`ask_yn()` to always answer yes; no tty always answers no.

## How to add or change a feature

### Add a new selectable language
1. Add a Dockerfile block guarded by `ARG <NAME>=false` in
   `.devcontainer/Dockerfile` (follow the existing `-- <Lang> ... # End <Lang>`
   pattern).
2. Register the language in `install.sh`: add it to both `VALID_LANGS` and the
   `lang_arg()` `case` (token → Dockerfile ARG name).
3. Create `templates/<lang>/` with any of: `extensions.json` (array),
   `settings.json` (JSONC), `<lang>gitignore`.
4. If the language needs verbatim extra files, add a branch to the
   per-language `case` in the "Per-language extra files" section.

The currently wired languages are `python`, `go`, `js`, and `dotnet`. `dotnet`
provides `extensions.json` and `dotnetgitignore` (no `settings.json` override
and no verbatim extras), driven by the `ARG DOTNET` block in the Dockerfile.

### Change container tooling
Edit `.devcontainer/Dockerfile`. Version pins live in `ARG`s at the top of each
block (e.g. `GO_URL`, `NODE_VER`, `DOTNET_VER`). Keep the `ARG X=false` +
`RUN if [ "$X" = "true" ]` shape so the feature stays opt-in.

### Change editor defaults for everyone
Edit `templates/basesettings.json` (merged into every project). Language-specific
overrides go in `templates/<lang>/settings.json`.

### Change Claude launch behavior
Edit `claude.sh`. Default CLI flags are the `CLAUDE_PARAMS` array near the top.

## Testing / verifying changes

Run `./test.sh` from the repo root. It's the standard way to verify any change
to `install.sh`: it patches a scratch copy of `install.sh` to `cp` from this
repo's working tree instead of `git clone`ing `--repo` (which install.sh always
does otherwise, even for `.` targets), so it exercises your **uncommitted**
changes directly — no need to push to a branch first. It runs a fixed set of
scaffold scenarios against `mktemp -d` targets and asserts on the output:
fresh scaffold (Dockerfile ARGs, valid JSON, gitignore contents), extensions
off-by-default vs. `--extensions` opt-in (present + deduped), idempotent
no-force reruns, and the `.gitignore`/`.vscode/settings.json` merge-on-conflict
behavior (existing wins with no tty, `--force` takes the generated value,
unrelated custom keys/lines always survive). Use `./test.sh -k <substring>` to
run a subset, `./test.sh --keep` to keep the scratch dirs for inspection on
failure. If you touch the exact `git clone` line in `install.sh`, `test.sh`'s
`make_local_install()` needs its `CLONE_LINE`/`CLONE_LINE2` updated to match —
it fails loudly instead of silently testing stale behavior.

For anything `test.sh` doesn't cover (e.g. actually building the container),
inspect by hand:

```bash
TMP=$(mktemp -d)
./install.sh --language python,go --force --target "$TMP" --repo lootem/devcontainer
# install.sh always clones --repo even for local runs; use --ref to test a
# pushed branch, or use test.sh (above) to test uncommitted changes directly.

cat "$TMP/.devcontainer/Dockerfile"        # ARGs flipped for selected langs?
cat "$TMP/.vscode/settings.json"           # base + lang settings merged, valid JSON?
cat "$TMP/.devcontainer/devcontainer.json" # extensions absent (default) or merged + deduped with --extensions?
cat "$TMP/.gitignore"
```

Other checks worth running on any change:
- Run through `shellcheck` if available.
- Confirm the container builds: open the generated folder in VS Code Dev
  Containers, or `docker build -f "$TMP/.devcontainer/Dockerfile" "$TMP"`.

## Conventions

- POSIX-ish Bash with `set -euo pipefail`; keep prompts reading from `/dev/tty`
  and the no-tty (CI/pipe) path working.
- Template JSON may use JSONC comments — they're stripped by `strip_jsonc()`
  before `jq` merges, so keep comments only in `templates/`, not in files copied
  verbatim.
- Keep Dockerfile features flag-gated and version-pinned via `ARG`.
