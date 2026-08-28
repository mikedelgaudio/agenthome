# AgentHome Phase 1 — Design Spec

_Status: Draft for review · 2026-08-27_

**Goal:** A local-first macOS app that detects when Claude Code and Codex drift apart in their global configuration, and reconciles them through a canonical store the user controls.

**Architecture:** A Rust core engine (adapters, canonical store, three-way drift reconciliation) behind a UniFFI boundary, consumed by a single always-running SwiftUI app whose primary surface is a menu bar item. The canonical store is a plain, unencrypted local git repository. A `agenthome` CLI links the same core and works headless.

**Tech Stack:** Rust (engine), UniFFI (FFI), SwiftUI (UI), SQLite via `rusqlite` (baseline index), `git2` (store history), `notify` + FSEvents (watching), `serde` (YAML/JSON/TOML).

**Upstream documents:** `agenthome-implementation-plan.md` (strategy), `agent_environment_manager_handoff.md` (product concept). This spec supersedes both wherever they conflict, and §3 documents where they were factually wrong.

---

## 1. Decisions locked before this spec

| # | Decision | Choice | Consequence |
|---|---|---|---|
| 1 | v1 scope | Full Phase 1: scan + project + drift + local git store + menu bar + reconcile UI | No sync, crypto, pairing, migration, or memory classification |
| 2 | Engine language | Rust core + UniFFI + SwiftUI shell | Portability preserved; FFI cost paid from day one |
| 3 | Config scope | Global only (`~/.claude`, `~/.codex`, `~/.claude.json`) | No project identity, repo discovery, or precedence chains |
| 4 | Write autonomy | Auto fast-forward; explicit for everything else | See §6.3 — revised during design |
| 5 | Adapters | Claude Code + Codex | Both dogfooded; real fixtures available for both |

### Non-goals for Phase 1

Sync between machines. Encryption or vaulting. QR pairing. Machine migration or inventory. Memory classification. Per-project configuration. Cursor, Gemini CLI, Windsurf, Copilot. Widgets, App Intents, Shortcuts, TipKit, Sparkle, notarized distribution.

These are deliberately excluded, not forgotten. Several are load-bearing for later phases; §15 records what Phase 1 must not foreclose.

---

## 2. Global constraints

- **Minimum macOS:** 15.0. Rationale: `MenuBarExtra` and `SMAppService` are stable, and the target user runs current systems.
- **Rust edition:** 2021, MSRV 1.82.
- **Swift:** 6.0, strict concurrency enabled.
- **The canonical store is plaintext.** No encryption anywhere in Phase 1.
- **AgentHome never stores, copies, or transmits a user secret.** See §13.
- **No network access.** The Phase 1 binary makes zero outbound connections. No telemetry, no update checks, no manifest fetching.
- **Every adapter path is an allowlist entry.** A denylist is a defect (§13.1).
- **Every persisted format carries `schema_version`.** No exceptions (§14.3).

---

## 3. Evidence base

This spec is grounded in a real installation rather than the upstream plan's assumptions. Findings below are from one machine (`n=1`) on 2026-08-27 and **must be re-validated against additional installs before the capability matrix in §7.4 is treated as settled.**

### 3.1 What actually exists

**Claude Code (`~/.claude/`, 23 entries):**

| Path | Nature |
|---|---|
| `settings.json` | Config. Keys: `effortLevel`, `enableWorkflows`, `enabledPlugins`, `extraKnownMarketplaces`, `model`, `skipDangerousModePermissionPrompt`, `statusLine`, `switchModelsOnFlag`, `tui` |
| `agents/*.md` | Config. One subagent present |
| `plugins/config.json`, `plugins/installed_plugins.json`, `plugins/known_marketplaces.json` | Config |
| `daemon/control.key` | **Credential** |
| `ide/`, `tasks/`, `cache/`, `plans/`, `projects/`, `session-env/`, `sessions/`, `shell-snapshots/`, `telemetry/`, `jobs/`, `file-history/`, `backups/`, `daemon.log`, `stats-cache.json` | Runtime sediment |

**`~/.claude.json` (60 KB, outside `~/.claude/`):** ~75 top-level keys, overwhelmingly caches, experiment flags, onboarding counters, and migration markers. Identity-bearing: `machineID`, `userID`, `oauthAccount`. Project state: `projects`. **No `mcpServers` key on this machine.**

**Codex (`~/.codex/`, 40 entries):**

| Path | Nature |
|---|---|
| `config.toml` | Config. `model`, `personality`, `model_reasoning_effort`, `service_tier`, `notify`, `[marketplaces.*]`, `[plugins."<name>@<marketplace>"]`, `[features]`, `[mcp_servers.*]` |
| `AGENTS.md` | Config — global instructions |
| `skills/.system/` | Vendor-bundled, not user-authored |
| `auth.json` | **Credential** |
| `memories_1.sqlite`, `state_5.sqlite`, `goals_1.sqlite`, `queue_1.sqlite`, `thread_history_1.sqlite`, `sessions/`, `shell_snapshots/`, `dictation-history/`, `transcription-history.jsonl`, `ambient-suggestions/`, `visualizations/`, `ipc/`, `thread-writer-locks/`, `cache/`, `tmp/`, `.tmp/`, `models_cache.json`, `installation_id` | Runtime sediment |

### 3.2 Four findings that reshape the design

1. **Config is a small minority of both trees.** Scanning `~/.claude` or `~/.codex` wholesale is never correct. The adapter primitive is an explicit path allowlist, not a directory walk. This is also why §12's scan budget is achievable.

2. **Live credentials sit inside the scan surface.** `~/.codex/auth.json`, `~/.claude/daemon/control.key`, and `oauthAccount` inside `~/.claude.json`. Any naive capture — especially the upstream plan's "fixture farm of captured real config trees" — commits secrets. §13 makes this structurally impossible.

3. **The upstream canonical model is largely aspirational.** `~/.agenthome/rules/`, `skills/`, `hooks/`, and `commands/` have no global native counterpart on either agent. Claude Code has no global `CLAUDE.md`, no `skills/`, no `commands/`, and no global permissions or hooks in `settings.json`. Building the store around those directories would produce a model with almost nothing in it.

4. **The genuinely shared concept is plugins and marketplaces.** Both agents independently converged on a marketplace + enabled-plugin model (`extraKnownMarketplaces`/`enabledPlugins` vs `[marketplaces.*]`/`[plugins."x@y"]`). Combined with instructions, MCP servers, and model preferences, this is the real v1 value, and it is not what the upstream plan optimized for.

### 3.3 Consequence for scope

Decision 1 in §1 chose global-only partly on the (incorrect) premise that skills, hooks, and permissions live globally. They do not. Global-only remains the right Phase 1 call — it is the only scope where the write path is safe to build first, and per-project work needs project identity that Phase 1 deliberately lacks — but the honest consequence is that **Phase 1's user-visible payoff is narrower than the upstream plan implies.** §16 carries this as the primary open risk.

---

## 4. Canonical model

### 4.1 The Item

Every managed thing is an **Item**. One Item is one file in the store.

```yaml
schema_version: 1
kind: mcp_server
id: "mcp_server:node_repl"
name: node_repl
spec:
  command: node
  args: ["--experimental-repl-await"]
  startup_timeout_sec: 30
  env:
    NODE_REPL_NODE_PATH: "/opt/homebrew/lib/node_modules"
provenance:
  first_seen_from: codex
  first_seen_at: "2026-08-27T21:00:00Z"
  last_promoted_from: codex
  last_promoted_at: "2026-08-27T21:04:11Z"
x_native:
  codex:
    service_tier: flex
```

**`spec`** is the portable, agent-independent representation. **`x_native`** preserves keys an agent emitted that the IR does not model, namespaced per agent. `x_native` is what makes round-trip idempotence (§14.1) achievable; without it every projection would silently strip unmodelled fields — precisely the "silent drop" the upstream plan forbids.

### 4.2 Identity

`id = "<kind>:<slug>"`. The slug is the item's native name, lowercased, with `[^a-z0-9._@-]` replaced by `-`.

Identity is **name-based, never content-based.** Content-addressed identity would make every edit look like a delete plus an add, destroying the baseline's ability to detect modification. The upstream plan's "content-addressed filenames where natural" is rejected for this reason.

Singleton kinds use the reserved slug `global` (e.g. `instructions:global`).

### 4.3 Kinds implemented in Phase 1

| Kind | Cardinality | Claude Code | Codex |
|---|---|---|---|
| `instructions` | singleton | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` |
| `mcp_server` | many | `~/.claude.json` → `mcpServers.<name>` | `config.toml` → `[mcp_servers.<name>]` |
| `subagent` | many | `~/.claude/agents/<name>.md` | *no native surface* |
| `marketplace` | many | `settings.json` → `extraKnownMarketplaces` | `config.toml` → `[marketplaces.<name>]` |
| `plugin` | many | `settings.json` → `enabledPlugins` | `config.toml` → `[plugins."<n>@<m>"]` |
| `model_preference` | singleton | `settings.json` → `model`, `effortLevel` | `config.toml` → `model`, `model_reasoning_effort` |
| `skill` | many | *no global native surface* | `~/.codex/skills/<name>/` |

### 4.4 Kinds deferred, with reasons

`rule`, `command`, `hook`, `permission` — no global native surface on either agent (§3.1). Modelling them now would be speculative. `memory` — Codex stores memories in `memories_1.sqlite`; reading another process's live SQLite database is out of scope for Phase 1 and is Phase 3 work regardless.

The IR reserves these kind names. Adding a kind is additive and does not require a schema version bump (§14.3).

---

## 5. Storage layout

Two locations with a hard boundary between them.

### 5.1 `~/.agenthome/` — canonical store

A plain git repository. Portable, user-readable, diffable, and the thing a future Phase 2 would encrypt and sync. Contains **only** canonical Items.

```text
~/.agenthome/
  .git/
  agenthome.yaml              # store metadata: schema_version, created_at, store_id
  instructions/global.md      # body is Markdown; front matter carries Item envelope
  mcp/<slug>.yaml
  subagents/<slug>.md
  marketplaces/<slug>.yaml
  plugins/<slug>.yaml
  model/global.yaml
  skills/<slug>/              # directory Item: skill.yaml + payload files
```

One file per Item, keys serialized in stable alphabetical order. Markdown-bodied kinds (`instructions`, `subagent`) carry the envelope as YAML front matter so the file stays natively readable.

### 5.2 `~/Library/Application Support/AgentHome/` — machine-local state

Never synced, never committed, `chmod 0700`.

```text
index.sqlite         # baselines, hashes, operation journal
snapshots/<agent>/<iso8601>-<slug>/   # pre-write copies of native files
logs/agenthome.log   # rotating, redacted
agenthome.lock       # advisory mutation lock
```

This split answers a question the upstream plan never resolved: what is portable intent versus what is derived machine state. Anything in Application Support can be deleted; the app rebuilds it by rescanning (with the cost that overrides in §6.4 are lost, so §11.3 exports them into the store).

---

## 6. Reconciliation

### 6.1 Why a baseline exists

The upstream plan asserts four drift event types but never says how to compute them. They are not computable from a two-way comparison. Given only "canonical set" and "agent set", a missing item is indistinguishable between *the user deleted it* and *we never delivered it* — and those demand opposite responses.

So AgentHome persists, per `(agent, item)`, the state it last observed or wrote. Reconciliation is then a three-way comparison — canonical, baseline, native — structurally identical to a git merge, where the baseline plays the role of the merge base.

### 6.2 Baseline record

```sql
CREATE TABLE baseline (
    agent          TEXT NOT NULL,
    item_id        TEXT NOT NULL,
    canonical_hash TEXT,               -- SHA-256 of canonical spec at last sync; NULL if never in canonical
    native_hash    TEXT,               -- SHA-256 of normalized native projection at last sync; NULL if never present
    native_locator TEXT NOT NULL,      -- file path, or path + JSON pointer for embedded items
    state          TEXT NOT NULL,      -- 'synced' | 'override' | 'unsupported'
    updated_at     TEXT NOT NULL,
    PRIMARY KEY (agent, item_id)
) STRICT;
```

Hashes are taken over the **normalized** form (§7.3), not raw bytes, so cosmetic reformatting by an agent is not drift.

### 6.3 The decision table

Let `C` = canonical changed vs `canonical_hash`, `N` = native changed vs `native_hash`.

| C | N | Event | Direction | Behavior |
|---|---|---|---|---|
| unchanged | unchanged | `clean` | — | nothing |
| **changed** | unchanged | `stale_in_agent` | canonical → agent | **automatic** |
| unchanged | **changed** | `changed_in_agent` | agent → canonical | explicit |
| unchanged | **added** | `new_in_agent` | agent → canonical | explicit |
| unchanged | **deleted** | `deleted_in_agent` | agent → canonical | explicit |
| **changed** | **changed** | `conflict` | both | explicit |
| **added** | absent | `stale_in_agent` | canonical → agent | **automatic** |
| **deleted** | unchanged | `retired` | canonical → agent | explicit |

**The rule: auto-apply fast-forwards, never auto-resolve conflicts.**

Approval attaches to the *canonical change*, not to each projection. When a user promotes an item into canonical they have already decided it should be shared; re-asking before it reaches the second agent is the same decision twice, and the second prompt is the one people dismiss — which is exactly how agents silently diverge. A `stale_in_agent` fast-forward is provably safe: the agent has not touched that item since baseline, so nothing can be overwritten.

Inbound direction always requires a human, because it is new information that needs judgment.

### 6.4 Guardrails on automatic writes

1. **Enrollment is explicit.** On first adoption every item looks stale. That initial import is always reviewed item-by-item. Auto-apply engages only once a baseline row exists for the agent.
2. **Never silent.** Every automatic projection updates the menu bar, appends a git commit to the store, and is revertible in one click from history (§11.2).
3. **Escape hatches.** Per-agent *manual mode* (all writes explicit) and a global *pause all writes*, both in Settings.
4. **Overrides are permanent.** Choosing *keep local* sets `state='override'`. That pair is then excluded from projection and never reported as drift again until the user clears it. This is what makes "keep local" honest rather than a dismissal that reappears tomorrow.

### 6.5 The transaction boundary

The single correctness-critical sequence in Phase 1. A native write and its baseline update must not diverge.

```text
1. journal: INSERT op(id, agent, item_id, intent, planned_hash, state='pending')
2. snapshot native file → snapshots/<agent>/<ts>-<slug>/
3. write temp file in destination directory, fsync, rename() over target
4. BEGIN; UPDATE baseline SET ...; UPDATE op SET state='committed'; COMMIT;
```

Crash recovery on launch: any `pending` op is resolved by re-hashing the native file. If it matches `planned_hash` the write landed — commit the baseline. Otherwise mark the op `failed` and leave the baseline untouched; the next scan reports honest drift.

Failure mode if step 4 fails after step 3: the next scan sees `native_hash` mismatch and reports `changed_in_agent`. The user is asked to review a change AgentHome itself made. That is a spurious prompt, never data loss — the correct direction to fail.

### 6.6 Self-write suppression

The watcher will observe AgentHome's own writes. Suppression is not a timing window or a state flag; it falls out of §6.5. Because the baseline is updated to the just-written hash inside the same transaction, the subsequent scan computes `N = unchanged` and emits `clean`. The baseline *is* the write-provenance journal.

---

## 7. Adapters

### 7.1 Manifest

Each adapter is a declarative TOML manifest plus a small amount of Rust for irregular translations. Manifests are compiled into the binary in Phase 1 — never fetched, because a remotely-supplied manifest that drives writes into `~/.claude` is a code-execution path (§13.3).

```toml
schema_version = 1
agent = "codex"
display_name = "Codex"
detect = ["~/.codex/config.toml"]

[[surface]]
kind = "instructions"
path = "~/.codex/AGENTS.md"
format = "markdown"

[[surface]]
kind = "mcp_server"
path = "~/.codex/config.toml"
format = "toml"
pointer = "mcp_servers"
collection = true

[[surface]]
kind = "skill"
path = "~/.codex/skills"
format = "directory"
collection = true
exclude = [".system"]          # vendor-bundled, not user content

deny = ["~/.codex/auth.json"]  # defense in depth; see §13.1
```

Every readable path is enumerated. There is no recursive walk and no wildcard that could pull in `sessions/` or `auth.json`.

### 7.2 Contracts

```rust
fn scan(&self, fs: &dyn FileSystem) -> Result<ScanResult>;
fn project(&self, items: &[Item], fs: &dyn FileSystem) -> Result<FidelityReport>;
```

```rust
pub enum Fidelity {
    Native,
    Lossy { reason: String, dropped: Vec<String> },
    Skipped { reason: SkipReason },
}

pub enum SkipReason {
    NoNativeSurface,      // agent has no equivalent concept
    ProviderSpecific,     // value cannot be translated (e.g. model IDs)
    UserOverride,         // baseline state = 'override'
}
```

`FidelityReport` must account for **every** input Item. An unaccounted item is a panic in debug and a hard error in release. Silent drops are structurally impossible, not merely discouraged.

### 7.3 Normalization

Before hashing or comparison, native content is normalized: parse to the IR, drop insignificant whitespace, sort map keys, and canonicalize scalars. This ensures an agent rewriting its own TOML with different key order is not reported as drift. Normalization is a pure function and is property-tested for idempotence.

### 7.4 Capability matrix

Derived from §3.1. `native` = faithful; `lossy` = translated with reported loss; `skipped` = no surface.

| Kind | Claude Code | Codex |
|---|---|---|
| `instructions` | native | native |
| `mcp_server` | native *(unverified — see §16)* | native |
| `subagent` | native | skipped — `NoNativeSurface` |
| `marketplace` | native | native |
| `plugin` | lossy — plugin identity is marketplace-scoped and not portable across agents | lossy — same |
| `model_preference` | lossy — `ProviderSpecific` model IDs and effort scales | lossy — same |
| `skill` | skipped — `NoNativeSurface` | native |

**Minimum capability contract.** Each adapter declares the kinds it must handle natively, asserted in tests (§14.2). Without this, the fidelity-completeness property is satisfiable by an adapter that marks everything `skipped` — a green build proving nothing.

- Claude Code must be native for: `instructions`, `subagent`, `marketplace`
- Codex must be native for: `instructions`, `mcp_server`, `marketplace`, `skill`

---

## 8. Drift engine

- Watches **only** the manifest's allowlisted paths via FSEvents behind a `FileWatcher` trait. For embedded items, the containing file is watched and the pointer re-evaluated.
- **Settle windows**: 2 s for config files. The upstream plan's 30–60 s memory window is not needed in Phase 1, because no memory kind is implemented (§4.4).
- On settle: read allowlisted paths, normalize, hash, compare against `baseline`, emit typed events per §6.3.
- **Coalescing**: events for the same `(agent, item)` within a settle window collapse to one evaluation of final state. AgentHome never acts on intermediate states — agents write configs non-atomically.
- **Gap recovery**: FSEvents can drop events. A full rescan runs at launch, on wake from sleep, and every 15 minutes. The watcher is an optimization; the rescan is the correctness guarantee.
- The engine never sits in an agent's path. Agents write natively at full speed; AgentHome only observes.

---

## 9. Process topology

The upstream plan is self-contradictory here: §6.2 puts `MenuBarExtra` in the app while §8 claims the main process launches only when a window opens. If a menu bar item is visible, that process is already running. Resolved as follows.

**One app process.** `AgentHome.app` hosts the `MenuBarExtra`, the main window, and the Settings scene. It owns the FSEvents watcher and the engine. Registered as a login item via `SMAppService` so the menu bar persists. There is no separate daemon in Phase 1.

**One CLI binary.** `agenthome` links the same Rust core and operates directly on the store. It works whether or not the app is running. No XPC in Phase 1 — an IPC layer would be the second-largest subsystem in the project and buys nothing while both clients can safely share state through the filesystem.

**Concurrency.** Mutating operations acquire an advisory `flock` on `agenthome.lock`; the second writer fails fast with a clear message rather than blocking. Reads never lock — SQLite runs in WAL mode. The app watches `~/.agenthome` itself, so CLI-driven changes appear in the UI without a restart.

**FFI shape.** The UniFFI boundary is coarse: commands in, events out. `scan_all() -> [DriftEvent]`, `apply(decisions: [Decision]) -> FidelityReport`, `history() -> [Commit]`. No chatty per-item calls, no shared mutable state across the boundary.

---

## 10. User interface

**Menu bar** is the daily surface. Glyph reflects worst current state across agents: clean / drift pending review / error. Dropdown lists each agent with its status and pending count, plus *Review changes*, *Rescan*, and *Pause writes*.

**Main window** is a `NavigationSplitView`: sidebar of agents with status badges, detail showing that agent's pending events grouped by direction (inbound needing review, outbound applied automatically). Per-item actions: *Promote*, *Keep local*, *Discard*. Conflicts show a three-pane diff — canonical, baseline, native.

**History** renders the store's git log: each entry is a structured event with a one-click revert.

Following the upstream plan's design rules, Liquid Glass applies only to chrome. Diffs, item lists, and fidelity tables sit on opaque backgrounds with SF Mono for content.

---

## 11. Failure handling

### 11.1 Partial projection

Applying a decision set across agents is not atomic across agents, and pretending otherwise would require rollback semantics AgentHome cannot honor. Each `(agent, item)` write is individually journaled and atomic (§6.5). If agent A succeeds and agent B fails, A stays applied, B is reported failed with its error, and the user retries B. The result screen names every failure explicitly.

### 11.2 Snapshots and revert

Every native file is copied to `snapshots/` before modification. Revert restores the snapshot and resets the baseline row to match.

**Retention:** the newest 20 snapshots per `(agent, item)`, or 14 days, whichever bound is hit first. Garbage collection runs at launch and after every apply. Snapshots are native files and may contain secrets, so they live in `Application Support` at `0700`, never in the store, never in git. Without a retention bound, snapshot-on-every-write would grow unbounded.

### 11.3 Store integrity

- Corrupt or unparseable canonical Item: quarantined to `.agenthome-quarantine/`, surfaced as an error, excluded from projection. One bad file never blocks the rest.
- Deleted `index.sqlite`: rebuilt by full rescan. Overrides would be lost, so they are also mirrored into `agenthome.yaml` under `overrides:` and restored on rebuild.
- Dirty git worktree at launch (hand-edited store): committed as `Manual edit` before any AgentHome operation, so history stays linear and no user edit is silently absorbed.

### 11.4 Enumerated conditions

Disk full during write (temp write fails; rename never runs; original intact). Native file unreadable (`Skipped` with reason; no crash). Native file changed between scan and apply (hash re-checked immediately before rename; mismatch aborts that item and re-reports drift). Agent uninstalled (surfaces vanish; adapter reports undetected; baselines retained for 30 days).

---

## 12. Performance budgets

The upstream plan's budgets are either untestable or contradicted by its own workload description. Restated so each is measurable, with the measurement defined.

| Metric | Budget | Measured how |
|---|---|---|
| Cold full scan, both agents | < 500 ms p95 | Criterion bench over the fixture farm. Justified by §3.2 — the allowlisted surface is a handful of files |
| Incremental drift evaluation after settle | < 100 ms p95 | Criterion; excludes the settle window, which is reported separately |
| Settle latency | 2 s, reported not budgeted | It is a deliberate delay, not a cost |
| Apply of a 50-item decision set | < 2 s p95 | Criterion against a temp-dir fixture machine |
| Menu bar idle RSS | Measure first, then set | Spiked in Task 1; hard fail above 100 MB. The plan's 30 MB is asserted without measurement and is unlikely for a SwiftUI process embedding Rust, SQLite, and libgit2 |
| Energy impact | Release gate, not CI | "Low in Activity Monitor" is not machine-checkable; it is a manual pre-release check |

Reference hardware for all benchmarks: Apple Silicon, warm filesystem cache, fixture farm as corpus. CI enforces the first four; the last two are release gates.

---

## 13. Security and privacy

### 13.1 Allowlist plus hard deny

Adapters read only enumerated paths (§7.1). Independently, a compiled-in deny list rejects known credential locations even if a manifest bug lists them: `~/.codex/auth.json`, `~/.claude/daemon/control.key`, `~/.claude/.credentials.json`, and the `oauthAccount`, `userID`, `machineID` pointers within `~/.claude.json`. Defense in depth — the allowlist is the control, the deny list catches allowlist mistakes.

### 13.2 Secrets are never canonicalized

MCP server definitions frequently carry tokens in `env`. During `scan()`, any env value matching a credential heuristic is **not** written to the store; the Item records `{secret_ref: {agent: codex, key: GITHUB_TOKEN}}` and the value stays in the native file. On projection to another agent, an unresolvable `secret_ref` yields `Lossy` with the missing key named, and the user is told which value to supply. Phase 1 has no secret resolution — no Keychain reads, no 1Password. It reports the gap honestly instead.

### 13.3 No remote code or configuration

No network access (§2). Manifests are compiled in, not fetched. This closes the path where a downloaded manifest causes writes into agent config directories.

### 13.4 Fixtures

Real config trees become fixtures only through a sanitizer, and a CI verifier fails the build if any fixture matches credential shapes (`sk-`, `ghp_`, `github_pat_`, JWT structure, `BEGIN * PRIVATE KEY`, high-entropy strings over 32 chars, or any filename on the §13.1 deny list). Given §3.2, this check is not optional.

---

## 14. Testing

### 14.1 Properties

- **Round-trip idempotence.** For any fixture `x`: `project(scan(x))` produces `x` modulo normalization, and a second `project` writes nothing. Run under a frozen clock and a fake filesystem.
- **Fidelity completeness.** Every Item in a projection appears exactly once in the `FidelityReport`.
- **Minimum capability.** Each adapter handles its §7.4 declared kinds as `Native`. This is what stops fidelity-completeness from being trivially satisfiable.
- **Normalization idempotence.** `normalize(normalize(x)) == normalize(x)`.
- **Identity stability.** Editing an Item's content never changes its `id`.

### 14.2 Decision table

Exhaustive table-driven tests over every row of §6.3, plus `override` and `unsupported` baseline states, plus the null cases (item absent from canonical, from native, from both). This is the correctness core; it is tested exhaustively rather than by example.

### 14.3 Schema versioning

Every persisted format — Item envelope, manifest, `agenthome.yaml`, SQLite schema — carries `schema_version`. Tests assert: a v1 reader rejects v2 files with a clear error rather than misparsing; unknown fields survive a round trip via `x_native`; and each SQLite migration is tested forward from a checked-in fixture database. Adding an Item kind is additive and does not bump the version.

### 14.4 Simulator, not FSEvents

Drift engine tests drive a virtual clock and scripted mutations through the `FileWatcher` trait. Deterministic, fast, no sleeps. One real-FSEvents integration test runs behind a feature flag and is not a CI gate.

### 14.5 Crash recovery

The §6.5 sequence is tested by injecting failure at each of the four steps and asserting the resulting state is one of: fully applied, fully unapplied, or reporting honest drift. Never silent divergence.

---

## 15. Out-of-scope reminders that Phase 1 must not foreclose

Phase 2 needs the store to be encryptable and syncable — hence §5.1's clean separation of portable intent from machine-local state, and §5.2's rule that nothing in Application Support is required to interpret the store. Phase 3 needs drift history as classifier training data — hence structured commits rather than per-save noise. Phase 4 needs inventory — no hooks required in Phase 1.

Explicitly **not** designed here, and not to be inferred from this document: any encryption format, any pairing protocol, any remote transport.

---

## 16. Open questions

1. **`n=1` evidence.** §3 comes from a single machine. The §7.4 matrix must be checked against at least two more real installs before adapters are considered complete. A user with a global `~/.claude/CLAUDE.md`, populated `skills/`, or configured `mcpServers` would expand the matrix.
2. **Claude Code MCP location unverified.** No `mcpServers` key exists in this `~/.claude.json`, so the read path in §4.3 is from documentation, not observation. Must be verified against an install that has MCP servers configured before the `mcp_server` kind is called native for Claude Code.
3. **Projection during an active session.** Writing permissions or model settings under a running agent is confusing but not corrupting. Phase 1 writes immediately and does not detect running agent processes. Revisit if it produces real confusion.
4. **Plugin portability.** §7.4 marks `plugin` lossy because identity is marketplace-scoped. Whether a useful cross-agent mapping exists is genuinely unknown and needs investigation, not a design decision.
5. **Thin-payoff risk (§3.3).** If real installs confirm the global surface is this sparse, Phase 1 may not be independently compelling, and per-project config — deferred by Decision 3 — may be where the value actually is. This is the largest product risk in the plan and should be re-examined after question 1 is answered.
