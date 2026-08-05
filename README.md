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
→ `main`). CI attests `install.sh` on every push to
`main` (`attest.yml`) via `actions/attest-build-provenance`. This is a
**provenance** guarantee (origin and build), not content-safety, and only holds
if you verify the *same* ref the URL serves - pin both to one sha.

### Options

| Option | What it does |
| --- | --- |
| `-l`, `--language <list>` | Language(s): `python`, `go`, `js`, `dotnet`. Comma-combine, or omit to be prompted. |
| `-T`, `--tool <list>` | Cloud/shell tool(s): `awscli`, `azcli`, `gh`, `pwsh`, `azpwsh`. Comma-combine. |
| `-c`, `--cli <list>` | AI coding CLI(s): `claude`, `codex`, `opencode`, `kiro`. Comma-combine, or omit for none. |
| `--skills` | Also bring the curated skills, into each selected CLI's skills dir. |
| `-t`, `--target <dir>` | Where to set things up (defaults to current folder). |
| `-f`, `--force` | Overwrite existing files without asking. |
| `--repo <owner/repo>` | Pull the template from a different repo (default `lootem/devcontainer`). |
| `--ref <ref>` | Use a specific branch, tag, or commit of the template. |
| `-h`, `--help` | Show all options. |

Enabling a tool only flips its Dockerfile build arg (no editor/`.gitignore`
entries, unlike languages). `azpwsh` implies `pwsh`, so you needn't pass both.

Selecting an AI CLI installs its binary for direct execution and gives it
project-local native state (`.claude/`, `.codex/`, `.opencode/`, or `.kiro/`). With
`--skills`, the curated skills are copied into `.claude/skills/`,
`.codex/skills/`, `.opencode/skills/`, or `.kiro/skills/`. Passing `--skills`
without at least one selected CLI is an error.

OpenCode installs the architecture-specific headless CLI package from npm. The
build verifies the package tarball against npm's published SHA-512 integrity
value before extracting `opencode`.

Kiro installs the official headless GNU/Linux artifact for the build's actual
architecture. Both amd64 and arm64 versioned URLs and SHA-256 values are pinned
in `.devcontainer/dependencies.lock.json`; Kiro's background updater is disabled.

### Keeping a generated repo up to date

Generated repositories commit `.devcontainer/scaffold.json` and the same executable installer at `.devcontainer/install.sh`. The metadata records desired feature selections and upstream provenance; it contains no target path, timestamp, credentials, or machine-local state.

Surgical updates refresh transplantable pins, dependency locks, signing material, extension pins, provenance, and the checked-in installer while preserving local structure:

```bash
.devcontainer/install.sh update
.devcontainer/install.sh update --ref <branch-tag-or-sha>
```

Use full mode for structural template changes or feature-selection changes. With a controlling terminal it summarizes the requested restamp before writing; in automation, pass `--force` explicitly:

```bash
.devcontainer/install.sh update --full
.devcontainer/install.sh update --full --force
```

The metadata is authoritative. If enabled Dockerfile features drift from it, update stops unless `--force` explicitly acknowledges that drift. Branch installs keep tracking their branch; an install pinned to a commit remains frozen until `--ref` replaces it.

## What you get

Open the folder in [VS Code](https://code.visualstudio.com/) with the
[Dev Containers](https://containers.dev/) extension and start working: a dev
container tuned for your language(s), with editor settings, optional recommended
extensions, and a starter `.gitignore`. Selected AI CLIs run by their native
command (`claude`, `codex`, `opencode`, or `kiro-cli`) and keep configuration, credentials,
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

Kiro supports interactive browser authentication persisted under `.kiro`; for
headless use, set `KIRO_API_KEY` in `.env` and uncomment its explicit Compose
mapping.

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

Kiro is a multi-artifact exception to ordinary single-pin updates. Renovate
dates releases from exact `kiro-cli <semver>` Homebrew cask commits, then runs
the narrowly allowlisted command below only after the age gate passes. The
command downloads both official Linux artifacts and atomically replaces both
hash records; Kiro updates never automerge.

```bash
./install.sh dependency-lock kiro <version>
```

The same dependency lock records the standalone AWS CLI signing key's path,
fingerprint, and expiry. The monthly key-refresh workflow verifies a live AWS
artifact before updating the armored key and lock metadata together.

**VS Code extensions.** Those on [OpenVSX](https://open-vsx.org) are pinned to an
exact version (`publisher.name@x.y.z`) and tracked by Renovate via a custom
datasource under the same gated rules (including several MS-published ones like
`ms-python.python`). Extensions not on OpenVSX (Remote Development pack, Pylance,
`ms-dotnettools.vscode-dotnet-pack`) float unpinned - but with
`extensions.autoUpdate`/`autoCheckUpdates` off, they won't silently update in a
running container. Generate a project without a fork and its own Renovate config,
and pins freeze at generation time; rerun `./install.sh -f` against a newer ref
to pick up updates.
