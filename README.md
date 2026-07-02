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
  formatting rules, and ignore patterns are already in place for Python, Go, or
  JavaScript/TypeScript.
- **AI tooling that just works** - Claude Code comes preconfigured, with an
  option to bring along a curated set of skills.
- **Less time on setup** - spend your first hour building, not configuring.

## Getting started

Go to the folder where you want your new project to live and run:

```bash
curl -fsSL https://raw.githubusercontent.com/lootem/devcontainer/main/install.sh | bash -s -- --language python
```

Swap `python` for `go` or `js`, or list several at once (`--language python,go`)
for a polyglot project. Leave the language off and it will simply ask you.

Prefer to clone first? Grab this repo and run `./install.sh` directly with the
same options.

### Options

| Option | What it does |
| --- | --- |
| `-l`, `--language <list>` | Language(s) to set up: `python`, `go`, `js`. Combine with commas, or omit to be prompted. |
| `--skills` | Also bring along the curated Claude Code skills. |
| `-t`, `--target <dir>` | Where to set things up (defaults to the current folder). |
| `-f`, `--force` | Overwrite existing files without asking. |
| `--repo <owner/repo>` | Pull the template from a different repo (defaults to `lootem/devcontainer`). |
| `--ref <ref>` | Use a specific branch, tag, or commit of the template. |
| `-h`, `--help` | Show all options. |

## What you get

Once it finishes, your folder has everything needed to open in
[VS Code](https://code.visualstudio.com/) with the
[Dev Containers](https://containers.dev/) extension and start working:

- A dev container tuned for the language(s) you chose.
- Editor settings and recommended extensions, already configured.
- A starter `.gitignore` suited to your language.
- Claude Code ready to run, and optionally a set of skills to go with it
  (add `--skills` to include them).

That's it - open the folder, let the container build, and start building.
