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
| `--skills` | Also bring the curated Claude Code skills. |
| `-t`, `--target <dir>` | Where to set things up (defaults to current folder). |
| `-f`, `--force` | Overwrite existing files without asking. |
| `--repo <owner/repo>` | Pull the template from a different repo (default `lootem/devcontainer`). |
| `--ref <ref>` | Use a specific branch, tag, or commit of the template. |
| `-h`, `--help` | Show all options. |

Enabling a tool only flips its Dockerfile build arg (no editor/`.gitignore`
entries, unlike languages). `azpwsh` implies `pwsh`, so you needn't pass both.

### Keeping a generated repo up to date

Every generated repo gets a `.devcontainer/update.sh` that detects your enabled
languages, tools, `--skills`, and `--extensions` and re-runs `install.sh`, so
you needn't remember your original flags. It's manual only, and re-syncing
resets the Dockerfile's pinned tool versions to whatever the target ref pins
upstream (expected - a generated repo has no Renovate config of its own).

```bash
.devcontainer/update.sh                 # re-sync against lootem/devcontainer@main
.devcontainer/update.sh --ref <sha>     # pin to a specific commit
.devcontainer/update.sh -- --force      # forward extra flags to install.sh
```

### Prefer a prebuilt image?

If you just want to `docker run`, prebuilt images are on [Docker Hub](https://hub.docker.com/repository/docker/lootemsec/devcontainer) as rolling
tags (rebuilt on every Dockerfile change on `main`, **amd64 only**):

```bash
docker pull lootemsec/devcontainer:python   # or go, js, dotnet
docker pull lootemsec/devcontainer:all      # every language + cloud CLI
```

Only `:all` includes the AWS/Azure CLIs and PowerShell; all images ship Claude
Code pre-installed with auto-update disabled. For reproducible, pinned, supply-
chain-gated builds, use `install.sh` instead.

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

## Bring your own Claude backend

The included `claude.sh` helper picks how you connect and remembers it in a
local `.env` (never committed). Copy `.env.example` to `.env`, fill in your
backend's fields, and switch providers with a word:

- **`./claude.sh api`** - Anthropic API, using your API key.
- **`./claude.sh bedrock`** - Amazon Bedrock, via a Bedrock API key, SSO profile, or AWS keys.
- **`./claude.sh foundry`** - Azure AI Foundry, via a Foundry API key or your `az login` session.
- No argument - defaults, with no backend override.

**Keep durable secrets encrypted at rest.** Run `./claude.sh keys init` (then
`keys edit`) to move your secret `KEY=VALUE` (ex. `ANTHROPIC_API_KEY`) lines out of `.env` into a
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
