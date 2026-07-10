# M1 Spike: Symlink-based Skill Deployment

Status: complete. Date: 2026-07-10. Machine: simon@darwin 25.5.0 (arm64, macOS 26).

## Question

Can skills be deployed to agents as **symlinked directories** — one canonical copy
in a Loadout library, a symlink in each agent's skills dir — recognized by
(a) Claude Code and (b) Codex CLI on this machine? This decides architecture
decision **D2: sync via symlink vs managed copies**.

## Method

1. Created a canonical probe skill OUTSIDE both agents' dirs:
   `/Users/simon/.claude/jobs/21ec5e9f/tmp/spike/loadout-symlink-probe/SKILL.md`
   (frontmatter `name: loadout-symlink-probe`, description ending "reply PROBE-OK").
2. Symlinked it into each agent dir:
   - `ln -s <canonical> ~/.claude/skills/loadout-symlink-probe`
   - `ln -s <canonical> ~/.codex/skills/loadout-symlink-probe`
3. Verified recognition the cheapest reliable way per agent (non-model where possible).
4. Tested edit propagation through the link, dangling-link behavior, and Loadout's
   own `SkillScan` against a symlink fixture (throwaway Swift; **no Swift source modified**).
5. Removed both symlinks and verified both dirs returned to original state.

Environment notes discovered during the spike:
- `claude` CLI: `/Users/simon/.local/bin/claude`, v2.1.206. No skills-list subcommand
  exists (`claude --help` commands: agents, auth, doctor, mcp, plugin, project, …),
  so a single cheap model invocation was used for Claude Code.
- **Codex has no CLI on `PATH`** (`codex not found`). It is installed as a desktop
  app (`brew` cask `codex-app`). The usable CLI binary lives at
  `/Applications/Codex.app/Contents/Resources/codex` (Mach-O arm64). `codex debug
  prompt-input` dumps the exact model-visible prompt as JSON — a zero-cost, no-model
  way to confirm skill injection.
- `~/.codex/skills` previously contained **only** `.system/` (imagegen, openai-docs,
  plugin-creator, skill-creator, skill-installer). Whether Codex scans non-`.system`
  user dirs was an open question this spike resolved (answer: **yes**).
- `timeout`/`gtimeout` are not installed; a `perl -e 'alarm shift; exec @ARGV'`
  wrapper was used as the kill-guard. No CLI hung.

## Findings

### (a) Claude Code — WORKS

Two independent pieces of evidence:

1. **Live harness rescan (free).** Immediately after `ln -s … ~/.claude/skills/loadout-symlink-probe`
   was created, the running Claude Code session's skill list updated to include:
   `loadout-symlink-probe: Probe skill for Loadout symlink spike…`. The harness
   discovered the symlinked directory on rescan.

2. **Fresh non-interactive model probe (one haiku shot).**
   ```
   $ claude -p "Is a skill named loadout-symlink-probe available to you? Answer yes or no only." --model haiku
   Yes.
   ```
   (exit 0). Claude Code injects the skill list at startup; the symlinked skill was
   present in that list.

Verdict: **Claude Code recognizes symlinked skill directories. Confidence: HIGH.**

### (b) Codex CLI — WORKS (and user-level skills ARE supported)

Zero-cost, no-model verification via the prompt dump:
```
$ /Applications/Codex.app/Contents/Resources/codex debug prompt-input
```
The rendered `<skills_instructions>` block lists the probe alongside `.system` and
plugin skills, with its source locator resolved to the **canonical path**:
```
- loadout-symlink-probe: Probe skill for Loadout symlink spike. When asked about
  loadout-symlink-probe, reply PROBE-OK.
  (file: /Users/simon/.claude/jobs/21ec5e9f/tmp/spike/loadout-symlink-probe/SKILL.md)
```
Key sub-findings:
- Codex **does** scan non-`.system` directories directly under `~/.codex/skills`
  (previously only `.system` existed there — user-level skills are supported).
- Codex resolves the symlink and reads `SKILL.md` at the canonical target; it even
  reports the resolved canonical path as the `file:` source locator.
- No model invocation was needed, so the single-shot budget for Codex was unused.

Verdict: **Codex CLI recognizes symlinked skill directories under `~/.codex/skills`.
Confidence: HIGH.**

### Edit propagation through the symlink — WORKS

Appending a line to the canonical `SKILL.md` was immediately visible through both
links (content and `stat` mtime updated), e.g. mtime `1783659440 -> 1783659545` and
the new last line `PROPAGATION-TEST-…` seen via both `~/.claude/skills/…/SKILL.md`
and `~/.codex/skills/…/SKILL.md`. (Canonical restored to clean probe content
afterward.) A single canonical edit propagates to every agent with no re-copy.

## Loadout scanner behavior with symlinks — BUG FOUND

Method: read `Sources/Loadout/Engine/SkillScan.swift` and ran a throwaway Swift
script that **mirrors its exact logic** against a fixture skills dir containing a
real skill (`real-skill`), a hidden `.system/` dir, and a symlink to the canonical
probe. No Swift source was modified.

Result — the symlinked skill is **NOT discovered**:
```
entry=loadout-symlink-probe isDir=false isSymlink=true
entry=real-skill            isDir=true  isSymlink=false
DISCOVERED: real-skill
```

Root cause. In `SkillScan.installations` (SkillScan.swift:30-32):
```swift
let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
    .isDirectory ?? false
guard isDirectory else { continue }
```
`URLResourceValues.isDirectory` (`.isDirectoryKey`) reflects the **symlink itself**,
not its target — for a directory symlink it returns `isDirectory=false,
isSymbolicLink=true`, so the entry is filtered out before the `SKILL.md` check ever
runs. The later `fileManager.fileExists(atPath:)` (line 36) *would* follow the link
correctly, but control never reaches it.

Impact scope. Both scanners depend on this helper, so **both agents' library scans
are affected** in Loadout:
- `ClaudeCodeScanner.swift:43, 79, 116` → `SkillScan.installations(in:)`
- `CodexScanner.swift:27, 32` → `SkillScan.installations(in:…)`

Consequence: even though both *agent CLIs* happily consume symlinked skills, Loadout's
own inventory UI would **not list a symlinked skill** — a correctness gap if D2 chooses
symlinks, since Loadout would deploy skills it then cannot see/manage.

### Suggested fix (for the integrator — not applied)

Make the directory test symlink-aware. Both of these were verified to return `true`
for a directory symlink on this machine:
- Approach A: `entry.resolvingSymlinksInPath()` then read `.isDirectoryKey`.
- Approach B: `FileManager.default.fileExists(atPath: entry.path, isDirectory: &b)`
  (follows symlinks).

Minimal, low-risk change — replace the `isDirectory` computation, e.g.:
```swift
var isDirObjC: ObjCBool = false
let exists = fileManager.fileExists(atPath: entry.path, isDirectory: &isDirObjC)
guard exists, isDirObjC.boolValue else { continue }
```
Both approaches still return `true` for ordinary directories, so `real-skill` and
existing behavior are preserved. Add a regression test with a symlinked fixture dir.
Note the hidden-name guard (`hasPrefix(".")`, line 33) is unaffected — `.system` is
still correctly excluded when `includeHidden` is false.

## Risks

- **Loadout scanner blindness (confirmed, above).** Must be fixed before symlink
  deployment is viable, or Loadout's UI will under-report deployed skills. This is the
  main blocker for D2=symlink and it is a small, well-scoped fix.
- **Dangling symlinks when the canonical is deleted.** Verified: with the canonical
  target removed, `FileManager.fileExists` through the link returns `false` (both the
  dir and its `SKILL.md`). Behavior is a **silent disappearance**, not an error — the
  skill simply stops being listed by the agents and (post-fix) by Loadout. Good: no
  crash. Risk: a user who deletes/moves the library leaves orphan links in agent dirs
  that never self-heal; Loadout should own link lifecycle (create/repair/remove) and
  consider a "prune dangling links" maintenance action.
- **Source path leakage.** Codex reports the canonical path as the skill's `file:`
  source locator in the model prompt. Loadout's canonical library location becomes
  visible to the model/agent — cosmetic, but worth knowing.
- **Cross-volume / iCloud paths.** Not tested. Symlinks across volumes or into
  iCloud-synced dirs may behave differently; if the library can live outside the home
  volume, add a follow-up check.
- **`.system` must stay untouched.** Codex's `.system` is managed by Codex; Loadout
  must only ever write user-level entries (never symlink into or modify `.system`).
  This spike honored that.

## Recommendation for D2

**Symlink deployment is viable for BOTH Claude Code and Codex CLI on this machine**
(both recognize symlinked skill dirs; a single canonical edit propagates to all
agents with no re-copy — the core advantage of the symlink model).

- Claude Code: symlink — **works, HIGH confidence.**
- Codex CLI: symlink into `~/.codex/skills/<slug>` (never `.system`) — **works,
  HIGH confidence.**

**Prerequisite:** fix the `SkillScan` directory-detection bug so Loadout can see the
skills it deploys. Until then, Loadout's own inventory is inconsistent with what the
agents actually load.

**Overall recommendation: choose D2 = symlink**, contingent on the one-line-ish
scanner fix, with Loadout owning symlink lifecycle (create, detect-dangling, prune).
Confidence: **HIGH** for feasibility; **MEDIUM-HIGH** for "ship it" pending the fix
and a cross-volume/iCloud sanity check. Managed copies remain the safer fallback if
avoiding any Swift change or dangling-link maintenance is preferred, at the cost of
losing single-source-of-truth propagation.

## Cleanup confirmation

Both probe symlinks removed; both agent dirs verified back to original state:
```
$ ls ~/.claude/skills | wc -l          -> 21   (probe: NONE)
$ ls -la ~/.codex/skills               -> only .system present
```
The canonical probe remains under the job tmp dir
(`/Users/simon/.claude/jobs/21ec5e9f/tmp/spike/loadout-symlink-probe/`), as allowed.
Throwaway Swift scripts and fixtures were deleted. `~/.codex/skills/.system` was never
touched. No settings/config files were modified. No git commands were run.
