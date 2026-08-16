# Loadout

**See, control, and sync your AI coding-agent skills across agents, projects, registries, and machines.**

Loadout is a native macOS app for making agent skills visible and manageable. It provides one place to understand what is installed, control which skills are active for each project, adopt skills into a personal collection, review updates, and recover safely when configuration changes go wrong.

## Why Loadout

Agent skills are increasingly part of a developer's working environment, but they are usually scattered across local folders, projects, agents, and registries. That makes it difficult to answer basic questions:

- Which skills are installed?
- Which projects use them?
- Where did each skill come from?
- Is an update available?
- What will change if I update?
- Can I undo the change?

Loadout turns that hidden configuration into a visible, reviewable system.

## What it does

- Discovers locally installed agent skills
- Enables or disables skills at project scope
- Supports local libraries and multiple registry adapters
- Adopts existing skills into a managed personal collection
- Checks for upstream updates
- Shows staged per-file diffs before applying changes
- Records configuration changes in a journal for undo and history
- Surfaces items that need attention
- Syncs a personal collection through iCloud
- Supports signed, notarized macOS releases and Sparkle updates

## Design principles

- **Review before mutation** — updates are staged and inspectable.
- **Reversible changes** — writes are recorded so they can be understood and undone.
- **Agent-agnostic configuration** — skills should move across tools without being trapped in one ecosystem.
- **Project awareness** — the useful unit is not only “installed globally,” but “active for this project.”
- **Native utility** — Loadout is designed as a focused macOS tool, not another agent chat interface.

## Stack

- Swift 6.1
- SwiftUI
- Swift Package Manager
- macOS 15+
- Yams for configuration parsing
- iCloud for personal collection sync
- Sparkle for application updates

The core implementation lives in `LoadoutKit`; the signed macOS application shell is kept separate so the library and tests stay independent of the updater.

## Development

Requirements:

- macOS 15+
- Xcode with Swift 6.1 support
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Run the test suite:

```sh
swift test
```

Build and install a development app alongside any released build:

```sh
make dev-install
```

This installs `/Applications/Loadout-dev.app`.

## Project status

Loadout is an evolving personal developer tool. The current repository represents an early public build and may change quickly as agent-skill formats and registries mature.

## Related work

- [Claude Agent SDK + Cloudflare Containers](https://github.com/simonlee2/claude-agent-cloudflare)
- [Claude Code plugins and reusable agent workflows](https://github.com/simonlee2/claude-plugins)
- [TypeScript MCP server template](https://github.com/simonlee2/mcp-server-ts)
