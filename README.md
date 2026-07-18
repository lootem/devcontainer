# Lootem's Dev Container Template

Pick your language and get a consistent, ready-to-code dev container in a single
command - the right editor extensions, formatting rules, `.gitignore`, and
Claude Code, already dialed in for Python, Go, JavaScript/TypeScript, or .NET.

## Getting started

From the folder where you want your new project to live:

```bash
# Interactive mode
curl -fsSL https://ltm.sh/dev | bash
# Non-interactive (example)
curl -fsSL https://ltm.sh/dev | bash -s -- --language python
# Update (overwrite) existing repo
curl -fsSL https://ltm.sh/dev | bash -s -- -f
```

Swap `python` for `go` or `js`, or list several (`--language python,go`) for a
polyglot project; omit the language to be prompted. Prefer to clone first? Run
`./install.sh` directly with the same options.

### Verify before you run

`curl | bash` trusts DNS, TLS, and whatever's at that URL without checking. To
verify provenance first (requires `gh` and network access to github.com):

```bash
curl -fsSL https://ltm.sh/dev/<sha> -o install.sh   # pin to a sha, not "main"
gh attestation verify install.sh --repo lootem/devcontainer
bash install.sh --language python
```

`ltm.sh/dev/<ref>` serves `install.sh` from any branch/tag/sha (bare `ltm.sh/dev`
→ `main`). CI attests `install.sh` and `.devcontainer/update.sh` on every push to
`main` (`attest.yml`) via `actions/attest-build-provenance`. This is a
**provenance** guarantee (origin and build), not content-safety, and only holds
if you verify the *same* ref the URL serves - pin both to one sha.

### Options

| Option | What it does |
| --- | --- |
| `-l`, `--language <list>` | Language(s): `python`, `go`, `js`, `dotnet`. Comma-combine, or omit to be prompted. |
| `-T`, `--tool <list>` | Cloud/shell tool(s): `awscli`, `azcli`, `gh`, `pwsh`, `azpwsh`. Comma-combine. |
| `-c`, `--cli <list>` | AI coding CLI(s): `claude`, `codex`. Comma-combine, or omit for `claude` (the default). |
| `--skills` | Also bring the curated skills, into each selected CLI's skills dir. |
| `-t`, `--target <dir>` | Where to set things up (defaults to current folder). |
| `-f`, `--force` | Overwrite existing files without asking. |
| `--repo <owner/repo>` | Pull the template from a different repo (default `lootem/devcontainer`). |
| `--ref <ref>` | Use a specific branch, tag, or commit of the template. |
| `-h`, `--help` | Show all options. |

Enabling a tool only flips its Dockerfile build arg (no editor/`.gitignore`
entries, unlike languages). `azpwsh` implies `pwsh`, so you needn't pass both.

Selecting an AI CLI installs its binary, copies its launcher (`claude.sh` for
`claude`, `codex.sh` for `codex`), and — with `--skills` — copies the curated
skills into that CLI's skills dir (`.claude/skills/` for Claude, `.agents/skills/`
for Codex; both read the same `SKILL.md` format).

### Keeping a generated repo up to date

Every generated repo gets a `.devcontainer/update.sh`, manual only. By default
it runs **surgical**: it fetches upstream's `Dockerfile` + `devcontainer.json`
(parsed only, never executed) and bumps in place every pinned version this
repo already tracks - each `# renovate:`-annotated `ARG`, the base image
`@sha256:` digest, and `devcontainer.json` extension `@version` pins - for keys
present both locally and upstream. Toggle `ARG`s, comments, and any other local
edits are left untouched. It prints a summary of what bumped and what was
skipped (and why).

```bash
.devcontainer/update.sh                 # bump pins from lootem/devcontainer@main
.devcontainer/update.sh --ref <sha>     # pin to a specific commit
.devcontainer/update.sh --repo <owner/repo>  # pull pins from a fork
```

`--full` instead re-runs `install.sh` and overwrites `.devcontainer/` wholesale
(the original behavior) - useful for pulling in structural upstream changes
(e.g. a new arch layout), but it clobbers local Dockerfile/devcontainer.json
edits:

```bash
.devcontainer/update.sh --full
.devcontainer/update.sh --full -- --force    # forward extra flags to install.sh
```

### Prefer a prebuilt image?

If you just want to `docker run`, a prebuilt image is on [Docker Hub](https://hub.docker.com/repository/docker/lootemsec/devcontainer) as a rolling,
multi-arch (**amd64 + arm64**) tag (rebuilt on every Dockerfile change on `main`):

```bash
docker pull lootemsec/devcontainer:all      # every language + cloud CLI
```

This single `:all` tag includes every language plus the AWS/Azure CLIs and
PowerShell; it ships Claude Code pre-installed with auto-update disabled. For
reproducible, pinned, supply-chain-gated, per-language builds, use `install.sh`
instead.

## What you get

Open the folder in [VS Code](https://code.visualstudio.com/) with the
[Dev Containers](https://containers.dev/) extension and start working: a dev
container tuned for your language(s), with editor settings, recommended
extensions, and a starter `.gitignore`, plus Claude Code ready to run (add
`--skills` for the curated skills; reruns only add/update, never remove ones
upstream dropped).

**Your Claude setup sticks around.** Claude Code points at a `.claude` folder
that lives with your project, not inside the throwaway container - so settings,
permissions, and history survive every rebuild, scoped per project.

## Bring your own backend

The `claude.sh` (and, for Codex, `codex.sh`) helper picks how you connect and
remembers it in a local `.env` (never committed). Copy `.env.example` to `.env`,
fill in your backend's fields, and just run the launcher — **the backend is
inferred from the environment variables you've set**, no argument needed:

- **`./claude.sh`** - Claude Code. Infers Anthropic API / Amazon Bedrock / Azure
  AI Foundry from what's set (e.g. `AWS_REGION`, `ANTHROPIC_FOUNDRY_RESOURCE`),
  or falls back to your API key. Force it with `CLAUDE_AUTH_MODE=api|bedrock|foundry`.
- **`./codex.sh`** - Codex. Infers OpenAI API / Azure OpenAI (e.g.
  `AZURE_OPENAI_BASE_URL`), or falls back to your API key / ChatGPT sign-in.
  Force it with `CODEX_AUTH_MODE=api|azure`.

If several backends' markers are set at once you're prompted to choose (or the
override var decides, for CI).

**Keep durable secrets encrypted at rest.** Run `./claude.sh keys init` (then
`keys edit`) — same subcommands on `codex.sh` — to move your secret `KEY=VALUE`
(ex. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) lines out of `.env` into a
gpg-encrypted `.env.keys.gpg`. It's decrypted to memory only when a backend needs
it - plaintext never touches disk to mitigate opportunistic disk
scraping.

## Built to reduce supply-chain risk

- **Everything is pinned** - base image to an exact digest, each tool to a named
  version - so builds are reproducible and a tampered upstream can't silently flow in.
- **You only install what you asked for** - per-language/tool build args, all
  defaulting to *off*. Smaller surface, fewer parts to trust.
- **Downloads are verified** where signatures exist (Claude Code, AWS CLI).

**Automated but gated version bumps.** Renovate (`renovate.json5`) and a base-
image-digest workflow open PRs but never merge blindly: minor/patch only (never
major), a 7-day supply-chain age gate, and the container must build with every
feature flag on (`build.yml`) before merge.

**VS Code extensions.** Those on [OpenVSX](https://open-vsx.org) are pinned to an
exact version (`publisher.name@x.y.z`) and tracked by Renovate via a custom
datasource under the same gated rules (including several MS-published ones like
`ms-python.python`). Extensions not on OpenVSX (Remote Development pack, Pylance,
`ms-dotnettools.vscode-dotnet-pack`) float unpinned - but with
`extensions.autoUpdate`/`autoCheckUpdates` off, they won't silently update in a
running container. Generate a project without a fork and its own Renovate config,
and pins freeze at generation time; rerun `./install.sh -f` against a newer ref
to pick up updates.
