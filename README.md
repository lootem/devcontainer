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
| `-c`, `--cli <list>` | AI coding CLI(s): `claude`, `codex`, `opencode`. Comma-combine, or omit for none. |
| `--skills` | Also bring the curated skills, into each selected CLI's skills dir. |
| `-t`, `--target <dir>` | Where to set things up (defaults to current folder). |
| `-f`, `--force` | Overwrite existing files without asking. |
| `--repo <owner/repo>` | Pull the template from a different repo (default `lootem/devcontainer`). |
| `--ref <ref>` | Use a specific branch, tag, or commit of the template. |
| `-h`, `--help` | Show all options. |

Enabling a tool only flips its Dockerfile build arg (no editor/`.gitignore`
entries, unlike languages). `azpwsh` implies `pwsh`, so you needn't pass both.

Selecting an AI CLI installs its binary for direct execution and gives it
project-local native state (`.claude/`, `.codex/`, or `.opencode/`). With
`--skills`, the curated skills are copied into `.claude/skills/`,
`.agents/skills/`, or `.opencode/skills/`. Passing `--skills` without at least
one selected CLI is an error.

OpenCode installs the architecture-specific headless CLI package from npm. The
build verifies the package tarball against npm's published SHA-512 integrity
value before extracting `opencode`.

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
PowerShell; it ships Codex pre-installed with update checks disabled. For
reproducible, pinned, supply-chain-gated, per-language builds, use `install.sh`
instead.

## What you get

Open the folder in [VS Code](https://code.visualstudio.com/) with the
[Dev Containers](https://containers.dev/) extension and start working: a dev
container tuned for your language(s), with editor settings, optional recommended
extensions, and a starter `.gitignore`. Selected AI CLIs run by their native
command (`claude`, `codex`, or `opencode`) and keep configuration, credentials,
and history in ignored workspace directories so they survive container rebuilds.
OpenCode's native `/connect` credentials persist under `.opencode/data`.

## Bring your own backend

Copy `.env.example` to the ignored `.env`, fill in the provider values you need,
then uncomment only their matching `${VAR:-}` entries in
`.devcontainer/docker-compose.yml`. Compose does not inject `.env` wholesale.
The documented first-class families are Anthropic API, AWS Bedrock, Azure AI
Foundry, OpenAI API, and Azure OpenAI.

Run each selected CLI directly. Claude consumes the Anthropic, Bedrock, and
Foundry variables natively. Codex consumes `OPENAI_API_KEY`; its generated
`model_providers.azure` configuration uses `AZURE_OPENAI_API_KEY` after you
replace the resource placeholder and select the Azure provider/model at the top
level of `.codex/config.toml`; its endpoint and API version are native TOML
settings rather than environment variables. OpenCode supports the documented
variables and its broader provider catalog through native configuration and
`/connect`.

Generated configuration disables CLI-managed updates while preserving unrelated
settings. The pinned container image remains the update boundary: rerun the
generator or rebuild against a newer ref to update a CLI.

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
