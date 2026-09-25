# agenthome

Single source of truth for global agent configuration across Claude Code, Codex, and GitHub Copilot CLI.

## What's here

| Path | Purpose |
| --- | --- |
| `global/AGENTS.md` | Global instructions loaded by every agent |
| `install.sh` | Symlinks each agent's global instructions path to `global/AGENTS.md` |
| `docs/` | Design specs for the AgentHome app |

## Onboard a new machine

```sh
git clone https://github.com/mikedelgaudio/agenthome.git ~/GitHub/agenthome
~/GitHub/agenthome/install.sh
```

This creates these symlinks:

| Agent | Global path | Points to |
| --- | --- | --- |
| Codex | `~/.codex/AGENTS.md` | `global/AGENTS.md` |
| Claude Code | `~/.claude/CLAUDE.md` | `global/AGENTS.md` |
| Copilot CLI | `~/.copilot/copilot-instructions.md` | `global/AGENTS.md` |

The script is idempotent. If a real file already exists at a target path, it is moved to `<path>.bak.<timestamp>` before linking — merge anything worth keeping from the backup into `global/AGENTS.md`, then delete the backup.

Restart any running agent sessions to pick up the instructions.

## Changing instructions

Edit `global/AGENTS.md`, commit, and push. On other machines, `git pull` — the symlinks pick up the change with no reinstall.

## For agents

When asked to set up or repair this store on a machine: clone the repo if absent, run `install.sh`, and verify each target in the table above is a symlink resolving to `global/AGENTS.md`. Do not copy the file into agent directories; always symlink. Never commit credentials (e.g. `~/.codex/auth.json`, `~/.claude/.credentials.json`) into this repo.
