# Lootem's Dev Container Template

Spinning up a new project shouldn't mean an afternoon of copy-pasting config
from your last one. This project turns that ritual into a single command: pick
your language, and get a consistent, ready-to-code environment every time.

## Why this exists

Every new repo tends to start the same way - set up a container, wire up the
editor, remember the right extensions and formatter, paste in a `.gitignore`,
and get your AI tooling pointed at the right place. It's tedious, easy to get
subtly wrong, and drifts from project to project.

This template captures a setup that's already dialed in and lets you stamp it
out on demand. The result is:

- **Consistency** - every project you create starts from the same trusted
  baseline, so switching between them feels the same.
- **A ready-to-open dev container** - open the folder, let it build, and you're
  coding in a clean, reproducible environment instead of fighting local setup.
- **Sensible defaults for your language** - the right editor extensions,
  formatting rules, and ignore patterns are already in place for Python, Go,
  JavaScript/TypeScript, or .NET.
- **AI tooling that just works** - Claude Code comes preconfigured, with an
  option to bring along a curated set of skills.
- **Less time on setup** - spend your first hour building, not configuring.

## Getting started

Go to the folder where you want your new project to live and run:

```bash
# Interactive mode
curl -fsSL https://ltm.sh/dev | bash
# Non-interactive (example)
curl -fsSL https://ltm.sh/dev | bash -s -- --language python
# Update (overwrite) existing repo
curl -fsSL https://ltm.sh/dev | bash -s -- -f
```

Swap `python` for `go` or `js`, or list several at once (`--language python,go`)
for a polyglot project. Leave the language off and it will simply ask you.

Prefer to clone first? Grab this repo and run `./install.sh` directly with the
same options.

### Verify before you run

`curl | bash` trusts three things at once: DNS, TLS, and whatever's sitting at
that URL right now. The one-liner above is the convenience path - fine for
casual use, but it never pauses to check any of that. If you want to verify
provenance first:

```bash
# Pin to a commit sha instead of the floating "main" the plain one-liner uses.
curl -fsSL https://ltm.sh/dev/<sha> -o install.sh

# Requires the GitHub CLI (gh) and network access to github.com.
gh attestation verify install.sh --repo lootem/devcontainer

bash install.sh --language python
```

`ltm.sh/dev/<ref>` is a Cloudflare redirect rule that maps any branch, tag, or
commit sha to `raw.githubusercontent.com/lootem/devcontainer/<ref>/install.sh`
(bare `ltm.sh/dev`, with no ref segment, keeps redirecting to `main`). CI
attests `install.sh` and `.devcontainer/update.sh` on every push to `main`
(`.github/workflows/attest.yml`) via `actions/attest-build-provenance`, so
`gh attestation verify` can confirm a given file came from a workflow run in
this repo at a specific commit.

That's a **provenance** guarantee, not a content-safety one - it proves origin
and build, not that the script is benign. And it only holds if you verify the
*same* ref the URL serves; pin both to the same commit sha, or the digests
won't line up.

### Options

| Option | What it does |
| --- | --- |
| `-l`, `--language <list>` | Language(s) to set up: `python`, `go`, `js`, `dotnet`. Combine with commas, or omit to be prompted. |
| `-T`, `--tool <list>` | Cloud/shell tool(s) to set up: `awscli`, `azcli`, `pwsh`, `azpwsh`. Combine with commas. |
| `--skills` | Also bring along the curated Claude Code skills. |
| `-t`, `--target <dir>` | Where to set things up (defaults to the current folder). |
| `-f`, `--force` | Overwrite existing files without asking. |
| `--repo <owner/repo>` | Pull the template from a different repo (defaults to `lootem/devcontainer`). |
| `--ref <ref>` | Use a specific branch, tag, or commit of the template. |
| `-h`, `--help` | Show all options. |

Enabling a tool only flips its Dockerfile build arg — there are no editor
settings or `.gitignore` entries tied to them, unlike languages. `azpwsh`
implies `pwsh` (the Dockerfile installs PowerShell if either `POWERSHELL` or
`AZPWSH` is true), so you don't need to pass both.

### Keeping a generated repo up to date

Every generated repo gets a `.devcontainer/update.sh`. It detects whichever
languages, tools, `--skills`, and `--extensions` you currently have enabled
and re-runs `install.sh` against them, so you don't have to remember your
original flags to pick up upstream changes:

```bash
.devcontainer/update.sh                 # re-sync against lootem/devcontainer@main
.devcontainer/update.sh --ref <sha>     # pin to a specific commit
.devcontainer/update.sh -- --force      # forward extra flags (e.g. --force) to install.sh
```

It's manual only - there's no devcontainer lifecycle hook running `curl|bash`
on your behalf. Note that re-syncing resets `.devcontainer/Dockerfile`'s
pinned tool versions to whatever the target ref currently pins upstream;
that's expected, since a generated repo has no Renovate config of its own to
bump those pins independently.

### Prefer a prebuilt image?

If you just want a container to `docker run` and don't need `install.sh`'s
generated project files, prebuilt images are published to Docker Hub for each
language plus one with everything enabled:

```bash
docker pull lootemsec/devcontainer:python   # or go, js, dotnet
docker pull lootemsec/devcontainer:all      # every language + cloud CLI
```

These are rolling tags (`:python`, `:go`, `:js`, `:dotnet`, `:all`) rebuilt on
every Dockerfile change on `main` - there are no pinned/dated tags. If you need
reproducible, pinned builds, use `install.sh`/the `curl` command above instead;
that's the path with supply-chain gating (see below). Images are **amd64
only** - on Apple Silicon or other arm64 hosts, run under emulation or use
`install.sh` to build locally. The `:python`/`:go`/`:js`/`:dotnet` images don't
include the AWS/Azure CLIs or PowerShell - only `:all` does. All images ship
Claude Code pre-installed with auto-update disabled.

## What you get

Once it finishes, your folder has everything needed to open in
[VS Code](https://code.visualstudio.com/) with the
[Dev Containers](https://containers.dev/) extension and start working:

- A dev container tuned for the language(s) you chose.
- Editor settings and recommended extensions, already configured.
- A starter `.gitignore` suited to your language.
- Claude Code ready to run, and optionally a set of skills to go with it
  (add `--skills` to include them). Rerunning with `--skills` only adds/updates
  skills - it never removes ones the upstream template has since dropped.

That's it - open the folder, let the container build, and start building.

## Your Claude setup sticks around

Rebuilding a container normally wipes everything that lived inside it - and
that usually includes your AI assistant's memory, preferences, and sign-in. Here
that isn't a problem.

Claude Code is pointed at a `.claude` folder that lives with your project rather
than inside the throwaway container. Because it's scoped to the project and
travels with your code, your settings, permissions, and history survive every
rebuild - and each project keeps its own setup instead of leaking into the
others. Rebuild as often as you like; Claude picks up right where you left off.

## Bring your own Claude backend

Not everyone runs Claude the same way, so the included `claude.sh` helper lets
you choose how to connect and remembers the details in a local `.env` file
(never committed). Just launch it with the backend you want:

- **`./claude.sh api`** - the Anthropic API, using your API key.
- **`./claude.sh bedrock`** - Amazon Bedrock, via a Bedrock API key, an SSO
  profile, or standard AWS access keys, whichever you have.
- **`./claude.sh foundry`** - Azure AI Foundry, via a Foundry API key or your
  existing `az login` session.

Run it with no argument to start Claude with the defaults and no backend
override. Copy `.env.example` to `.env`, fill in the fields for your chosen
backend, and you're set - switching providers is just a different word on the
command line.

## Built to reduce supply-chain risk

A dev environment is only as trustworthy as the things it downloads while being
built. This template is deliberately conservative about that.

- **Everything is pinned.** The base image is locked to an exact digest, and
  each tool - Go, Node, Poetry, the AWS/Azure CLIs, PowerShell, and more - is
  installed at a specific, named version rather than "whatever's latest today."
  That means your container builds the same way tomorrow as it does now, and an
  upstream package being tampered with doesn't silently flow into your build.
- **You only install what you asked for.** The container is assembled from
  build arguments (one per language and tool), and everything defaults to *off*.
  Choosing `python` simply flips that one switch on. A smaller surface means
  fewer moving parts to trust.
- **Downloads are verified.** Where a tool publishes signatures (such as Claude
  Code and the AWS CLI), the build checks them before trusting the download.

### Version bumps are automated, but gated

Renovate opens PRs for the pinned versions in `.devcontainer/Dockerfile`
(see `renovate.json5`), and a bespoke workflow does the same for the base
image digest (`.github/workflows/base-image-digest.yml`), but neither one
merges blindly:

- **Never a major bump.** Only minor/patch updates (and the base image
  digest) are ever proposed automatically.
- **7-day supply-chain gate.** A release has to be at least a week old
  before Renovate (or the base-image workflow) will even open a PR - long
  enough for malware scanners to catch a compromised release before it
  reaches this template.
- **The container has to actually build first.** Every bump PR runs
  `.github/workflows/build.yml`, which builds the Dockerfile with every
  feature flag on, before it's allowed to merge.

### VS Code extensions: pinned where possible, floating otherwise

The recommended extensions in `templates/*/extensions.json` get the same
gated-update treatment where it's available:

- **Extensions available on [OpenVSX](https://open-vsx.org) are pinned** to an
  exact version (`publisher.name@x.y.z`) and tracked by Renovate through a
  custom OpenVSX datasource, since Renovate has no built-in VS Code extension
  updater. This is decided by OpenVSX availability, not publisher — several
  Microsoft-published extensions (`ms-python.python`, `ms-python.black-formatter`,
  `ms-vscode.makefile-tools`, `ms-azuretools.vscode-containers`) publish there
  and so are pinned. This applies in both `templates/*/extensions.json` and the
  base `.devcontainer/devcontainer.json`. They go through the same
  major-bump-never, 7-day-gate, build-must-pass rules as everything else.
- **Extensions not on OpenVSX are left unpinned** (e.g. the Remote Development
  pack `ms-vscode-remote.vscode-remote-extensionpack`, `ms-vscode.remote-explorer`,
  `ms-dotnettools.vscode-dotnet-pack`, Pylance) - Renovate has no datasource
  that can track them, so they float at whatever version the Marketplace serves. Since `extensions.autoUpdate` and
  `extensions.autoCheckUpdates` are both off in the generated
  `devcontainer.json`, they won't silently update inside a running container
  either - they're just not gated by this template's update flow.
- If you generate a project without a fork of this template and its own
  Renovate config, pinned versions freeze at generation time; rerun
  `./install.sh -f` against a newer template ref to pick up updates.