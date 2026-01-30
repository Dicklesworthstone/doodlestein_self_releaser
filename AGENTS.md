# AGENTS.md — dsr (Doodlestein Self-Releaser) Project

## RULE 1 – ABSOLUTE (DO NOT EVER VIOLATE THIS)

You may NOT delete any file or directory unless I explicitly give the exact command **in this session**.

- This includes files you just created (tests, tmp files, scripts, etc.).
- You do not get to decide that something is "safe" to remove.
- If you think something should be removed, stop and ask. You must receive clear written approval **before** any deletion command is even proposed.

Treat "never delete files without permission" as a hard invariant.

---

## IRREVERSIBLE GIT & FILESYSTEM ACTIONS

Absolutely forbidden unless I give the **exact command and explicit approval** in the same message:

- `git reset --hard`
- `git clean -fd`
- `rm -rf`
- Any command that can delete or overwrite code/data

Rules:

1. If you are not 100% sure what a command will delete, do not propose or run it. Ask first.
2. Prefer safe tools: `git status`, `git diff`, `git stash`, copying to backups, etc.
3. After approval, restate the command verbatim, list what it will affect, and wait for confirmation.
4. When a destructive command is run, record in your response:
   - The exact user text authorizing it
   - The command run
   - When you ran it

If that audit trail is missing, then you must act as if the operation never happened.

---

## Shell / Bash Discipline

- This is a **pure Bash project**. The main script `dsr` and supporting modules are shell scripts.
- Target **Bash 4.0+** compatibility. Use `#!/usr/bin/env bash` shebang.
- Do NOT use `set -e` globally — handle errors explicitly to ensure processing continues after individual failures.
- Use `set -uo pipefail` instead.
- Use ShellCheck to lint all scripts. Address all warnings at severity `warning` or higher.

### Key Patterns from the Plan

- **No string parsing for git status** — use git plumbing commands (e.g., `git rev-list --left-right --count`)
- **No global `cd`** — always use `git -C "$repo_path"` instead
- **Stream separation** — stderr for human-readable output, stdout for structured data (JSON, paths)
- **Explicit error handling** — capture exit codes with `if output=$(cmd 2>&1); then ... else exit_code=$?; fi`

---

## Development Workspace Hygiene

**CRITICAL**: Do NOT create git worktrees, clones, or any other directories in `/data/projects/` (or the user's projects directory). This directory is managed and should only contain configured repositories.

### Forbidden Actions

- `git worktree add /data/projects/doodlestein_self_releaser_*` — creates clutter that confuses users
- Cloning repos to `/data/projects/` for "testing" or "exploration"
- Creating any subdirectories in the projects folder that aren't managed

### Correct Approaches

For development/testing that requires separate working directories:

1. **Use `/tmp/`** — create temporary directories with `mktemp -d`
2. **Use the existing repo** — work in the current checkout, create branches if needed
3. **Clean up after yourself** — if you must create temporary files/dirs, remove them when done

The tests demonstrate the correct pattern:
```bash
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
# ... run tests ...
rm -rf "$TEMP_DIR"  # cleanup
```

---

## Project Architecture

**dsr** (Doodlestein Self-Releaser) is a fallback release infrastructure for when GitHub Actions is throttled (>10 min queue time). It:

- Detects GH Actions throttling via queue time monitoring
- Triggers local builds using `nektos/act` (reusing exact GH Actions YAML)
- Distributes builds across Linux (trj), macOS (mmini), Windows (wlap)
- Generates smart curl-bash installers with staleness detection
- Signs artifacts with minisign and generates SBOMs

### Build Machines

| Machine | Platform | Connection | Purpose |
|---------|----------|------------|---------|
| trj | Linux x64 | local | Primary build host, act runner |
| mmini | macOS arm64 | SSH via Tailscale | Native macOS builds |
| wlap | Windows x64 | SSH via Tailscale | Native Windows builds |

### Build Strategy

- **Linux**: nektos/act reuses GH Actions YAML in Docker containers
- **macOS**: SSH to mmini, run native compilation
- **Windows**: SSH to wlap, run native compilation

### Subcommands

| Command | Purpose | Key Options |
|---------|---------|-------------|
| `check` | Detect throttled GH Actions runs | `--repos`, `--threshold`, `--all` |
| `watch` | Continuous monitoring daemon | `--interval`, `--auto-fallback`, `--notify` |
| `build` | Build artifacts locally | `--repo`, `--targets`, `--version`, `--workflow` |
| `release` | Upload artifacts to GitHub | `--repo`, `--version`, `--draft`, `--prerelease` |
| `fallback` | Full pipeline: check → build → release | `--repo`, `--version` |
| `repos` | Manage repository registry | `list`, `add`, `remove`, `sync` |
| `config` | View/modify configuration | `show`, `set`, `get`, `init` |
| `doctor` | System diagnostics | `--fix` |

---

## Repo Layout

```
doodlestein_self_releaser/
├── dsr                               # Main CLI script (planned)
├── src/
│   └── act_runner.sh                 # nektos/act integration module
├── scripts/
│   ├── toolchain_check.sh            # Cross-machine toolchain harmonization
│   └── tests/
│       ├── test_act_runner.sh        # act_runner unit tests
│       ├── test_json_schemas.sh      # JSON schema validation tests
│       └── fixtures/                 # Test fixtures (JSON)
├── schemas/
│   ├── envelope.json                 # Base JSON response schema
│   ├── check-details.json            # dsr check command schema
│   ├── build-details.json            # dsr build command schema
│   ├── release-details.json          # dsr release command schema
│   └── doctor-details.json           # dsr doctor command schema
├── config/
│   └── actrc.example                 # Sample ~/.actrc configuration
├── docs/
│   ├── CLI_CONTRACT.md               # Authoritative CLI specification
│   └── ACT_SETUP.md                  # nektos/act installation guide
├── README.md                         # User documentation
├── AGENTS.md                         # This file
└── .beads/                           # Issue tracking (br)
```

---

## XDG Configuration Layout

```
~/.config/dsr/
├── config.yaml               # Main configuration
└── repos.d/
    └── *.yaml                # Per-repo build configurations

~/.cache/dsr/
├── act/                      # act Docker layer cache
└── builds/                   # Cached build artifacts

~/.local/state/dsr/
├── logs/
│   ├── YYYY-MM-DD/
│   │   ├── run.log           # Main run log
│   │   └── builds/
│   │       └── *.log         # Per-build logs
│   └── latest -> YYYY-MM-DD  # Symlink to latest run
├── artifacts/                # Build artifacts
└── manifests/                # Build manifests
```

---

## Exit Codes

| Code | Name | Meaning |
|------|------|---------|
| `0` | SUCCESS | Operation completed successfully |
| `1` | PARTIAL_FAILURE | Some targets/repos failed |
| `2` | CONFLICT | Blocked by pending run/lock |
| `3` | DEPENDENCY_ERROR | Missing gh auth, docker, ssh, etc. |
| `4` | INVALID_ARGS | Bad CLI options or config |
| `5` | INTERRUPTED | User abort (Ctrl+C) or timeout |
| `6` | BUILD_FAILED | Build/compilation error |
| `7` | RELEASE_FAILED | Upload/signing failed |
| `8` | NETWORK_ERROR | Network connectivity issue |

---

## Generated Files — NEVER Edit Manually

**Current state:** There are **no checked-in generated source files** in this repo.

If/when we add generated artifacts:

- **Rule:** Never hand-edit generated outputs.
- **Convention:** Put generated outputs in a clearly labeled directory and document the generator command adjacent to it.

---

## Code Editing Discipline

- Do **not** run scripts that bulk-modify code (codemods, invented one-off scripts, giant `sed`/regex refactors).
- Large mechanical changes: break into smaller, explicit edits and review diffs.
- Subtle/complex changes: edit by hand, file-by-file, with careful reasoning.

---

## Backwards Compatibility & File Sprawl

We optimize for a clean architecture now, not backwards compatibility.

- No "compat shims" or "v2" file clones.
- When changing behavior, migrate callers and remove old code.
- New files are only for genuinely new domains that don't fit existing modules.
- The bar for adding files is very high.

---

## Console Output Design

This project has a CLI tool (`dsr`) and supporting modules.

Output stream rules:
- **stderr**: All human-readable output (progress, errors, summary, help)
- **stdout**: Only structured output (JSON in `--json` mode, paths otherwise)

Visual design:
- Use **gum** when available for beautiful terminal UI
- Fall back to ANSI color codes when gum is unavailable
- Non-interactive mode (`--non-interactive`) suppresses prompts for CI/automation

---

## Tooling Assumptions (recommended)

This section is a **developer toolbelt** reference.

### Shell & Terminal UX
- **zsh** + **oh-my-zsh** + **powerlevel10k**
- **lsd** (or eza fallback) — Modern ls
- **atuin** — Shell history with Ctrl-R
- **fzf** — Fuzzy finder
- **zoxide** — Better cd
- **direnv** — Directory-specific env vars

### Dev Tools
- **tmux** — Terminal multiplexer
- **ripgrep** (`rg`) — Fast search
- **ast-grep** (`sg`) — Structural search/replace
- **lazygit** — Git TUI
- **bat** — Better cat
- **gum** — Glamorous shell scripts (used by dsr for UI)
- **ShellCheck** — Shell script linter

### Coding Agents
- **Claude Code** — Anthropic's coding agent
- **Codex CLI** — OpenAI's coding agent
- **Gemini CLI** — Google's coding agent

### Dependencies for dsr
- **git** — Version control
- **gh** — GitHub CLI (for API access, releases)
- **docker** — For nektos/act containers
- **act** — nektos/act for running GH Actions locally
- **ssh** — For remote builds on mmini/wlap
- **minisign** — For artifact signing
- **syft** — For SBOM generation
- **jq** — JSON parsing

### Dicklesworthstone Stack (all 8 tools)
1. **ntm** — Named Tmux Manager (agent cockpit)
2. **mcp_agent_mail** — Agent coordination via mail-like messaging
3. **ultimate_bug_scanner** (`ubs`) — Bug scanning with guardrails
4. **beads_viewer** (`bv`) — Task management TUI
5. **coding_agent_session_search** (`cass`) — Unified agent history search
6. **cass_memory_system** (`cm`) — Procedural memory for agents
7. **coding_agent_account_manager** (`caam`) — Agent auth switching
8. **simultaneous_launch_button** (`slb`) — Two-person rule for dangerous commands

---

## MCP Agent Mail — Multi-Agent Coordination

Agent Mail is available as an MCP server for coordinating work across agents.

### CRITICAL: How Agents Access Agent Mail

**Coding agents (Claude Code, Codex, Gemini CLI) access Agent Mail NATIVELY via MCP tools.**

- You do NOT need to implement HTTP wrappers, client classes, or JSON-RPC handling
- MCP tools are available directly in your environment (e.g., `macro_start_session`, `send_message`, `fetch_inbox`)
- If MCP tools aren't available, flag it to the user — they may need to start the Agent Mail server

What Agent Mail gives:
- Identities, inbox/outbox, searchable threads.
- Advisory file reservations (leases) to avoid agents clobbering each other.
- Persistent artifacts in git (human-auditable).

Core patterns:

1. **Same repo**
   - Register identity:
     - `ensure_project` then `register_agent` with the repo's absolute path as `project_key`.
   - Reserve files before editing:
     - `file_reservation_paths(project_key, agent_name, ["src/act_runner.sh", "scripts/toolchain_check.sh"], ttl_seconds=3600, exclusive=true)`.
   - Communicate:
     - `send_message(..., thread_id="FEAT-123")`.
     - `fetch_inbox`, then `acknowledge_message`.
   - Fast reads:
     - `resource://inbox/{Agent}?project=<abs-path>&limit=20`.
     - `resource://thread/{id}?project=<abs-path>&include_bodies=true`.

2. **Macros vs granular:**
   - Prefer macros when speed is more important than fine-grained control:
     - `macro_start_session`, `macro_prepare_thread`, `macro_file_reservation_cycle`, `macro_contact_handshake`.
   - Use granular tools when you need explicit behavior.

Common pitfalls:
- "from_agent not registered" → call `register_agent` with correct `project_key`.
- `FILE_RESERVATION_CONFLICT` → adjust patterns, wait for expiry, or use non-exclusive reservation.

---

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - ShellCheck, syntax validation, tests
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   br sync --flush-only
   git add .beads/
   git commit -m "Sync beads"
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds


---

## Issue Tracking with br (beads_rust)

All issue tracking goes through **br**. No other TODO systems.

**Note:** `br` is non-invasive and never executes git commands. You must manually add, commit, and push `.beads/` changes.

**SQLite/WAL Caution:** br uses SQLite with WAL mode. Always run `br sync --flush-only` before git operations to ensure `.beads/` files are consistent.

Key invariants:

- `.beads/` is authoritative state and **must always be committed** with code changes.
- Do not edit `.beads/*.jsonl` directly; only via `br`.

### Basics

Check ready work:

```bash
br ready --json
```

Create issues:

```bash
br create "Issue title" -t bug|feature|task -p 0-4 --json
br create "Issue title" -p 1 --deps discovered-from:br-123 --json
```

Update:

```bash
br update br-42 --status in_progress --json
br update br-42 --priority 1 --json
```

Complete:

```bash
br close br-42 --reason "Completed" --json
```

Sync workflow:

```bash
br sync --flush-only
git add .beads/
git commit -m "Sync beads"
git push
```

Types:

- `bug`, `feature`, `task`, `epic`, `chore`

Priorities:

- `0` critical (security, data loss, broken builds)
- `1` high
- `2` medium (default)
- `3` low
- `4` backlog

Agent workflow:

1. `br ready` to find unblocked work.
2. Claim: `br update <id> --status in_progress`.
3. Implement + test.
4. If you discover new work, create a new bead with `discovered-from:<parent-id>`.
5. Close when done.
6. Commit `.beads/` in the same commit as code changes.

Sync:

- Run `br sync --flush-only` to export to `.beads/issues.jsonl`.
- Then manually `git add .beads/ && git commit && git push`.

Never:

- Use markdown TODO lists.
- Use other trackers.
- Duplicate tracking.

---

### Using bv as an AI sidecar

bv is a graph-aware triage engine for Beads projects (.beads/beads.jsonl). Instead of parsing JSONL or hallucinating graph traversal, use robot flags for deterministic, dependency-aware outputs with precomputed metrics (PageRank, betweenness, critical path, cycles, HITS, eigenvector, k-core).

**Scope boundary:** bv handles *what to work on* (triage, priority, planning). For agent-to-agent coordination (messaging, work claiming, file reservations), use MCP Agent Mail, which should be available to you as an MCP server (if it's not, then flag to the user; they might need to start Agent Mail using the `am` alias or by running `cd "<directory_where_they_installed_agent_mail>/mcp_agent_mail" && bash scripts/run_server_with_token.sh)' if the alias isn't available or isn't working.

**Use ONLY `--robot-*` flags. Bare `bv` launches an interactive TUI that blocks your session.**

#### The Workflow: Start With Triage

**`bv --robot-triage` is your single entry point.** It returns everything you need in one call:
- `quick_ref`: at-a-glance counts + top 3 picks
- `recommendations`: ranked actionable items with scores, reasons, unblock info
- `quick_wins`: low-effort high-impact items
- `blockers_to_clear`: items that unblock the most downstream work
- `project_health`: status/type/priority distributions, graph metrics
- `commands`: copy-paste shell commands for next steps

```bash
bv --robot-triage        # THE MEGA-COMMAND: start here
bv --robot-next          # Minimal: just the single top pick + claim command
```

#### Other bv Commands

**Planning:**
| Command | Returns |
|---------|---------|
| `--robot-plan` | Parallel execution tracks with `unblocks` lists |
| `--robot-priority` | Priority misalignment detection with confidence |

**Graph Analysis:**
| Command | Returns |
|---------|---------|
| `--robot-insights` | Full metrics: PageRank, betweenness, HITS, eigenvector, critical path, cycles, k-core, articulation points, slack |

Use bv instead of parsing beads.jsonl—it computes PageRank, critical paths, cycles, and parallel tracks deterministically.

---

### Morph Warp Grep — AI-Powered Code Search

Use `mcp__morph-mcp__warp_grep` for "how does X work?" discovery across the codebase.

When to use:

- You don't know where something lives.
- You want data flow across multiple files.
- You want all touchpoints of a cross-cutting concern.

Example:

```
mcp__morph-mcp__warp_grep(
  repoPath: "/data/projects/doodlestein_self_releaser",
  query: "How does act_runner determine if a job can run locally vs needs SSH?"
)
```

Warp Grep:

- Expands a natural-language query to multiple search patterns.
- Runs targeted greps, reads code, follows imports, then returns concise snippets with line numbers.
- Reduces token usage by returning only relevant slices, not entire files.

When **not** to use Warp Grep:

- You already know the function/identifier name; use `rg`.
- You know the exact file; just open it.
- You only need a yes/no existence check.

Comparison:

| Scenario | Tool |
| ---------------------------------- | ---------- |
| "How does act workflow analysis work?" | warp_grep |
| "Where is `act_can_run` defined?" | `rg` |
| "Replace `var` with `let`" | `ast-grep` |

---

### cass — Cross-Agent Search

`cass` indexes prior agent conversations (Claude Code, Codex, Cursor, Gemini, ChatGPT, etc.) so we can reuse solved problems.

Rules:

- Never run bare `cass` (TUI). Always use `--robot` or `--json`.

Examples:

```bash
cass health
cass search "bash error handling" --robot --limit 5
cass view /path/to/session.jsonl -n 42 --json
cass expand /path/to/session.jsonl -n 42 -C 3 --json
cass capabilities --json
cass robot-docs guide
```

Tips:

- Use `--fields minimal` for lean output.
- Filter by agent with `--agent`.
- Use `--days N` to limit to recent history.

stdout is data-only, stderr is diagnostics; exit code 0 means success.

Treat cass as a way to avoid re-solving problems other agents already handled.

---

## Memory System: cass-memory

The Cass Memory System (cm) is a tool for giving agents an effective memory based on the ability to quickly search across previous coding agent sessions and then reflect on what they find and learn in new sessions to draw out useful lessons and takeaways.

### Quick Start

```bash
# 1. Check status and see recommendations
cm onboard status

# 2. Get sessions to analyze (filtered by gaps in your playbook)
cm onboard sample --fill-gaps

# 3. Read a session with rich context
cm onboard read /path/to/session.jsonl --template

# 4. Add extracted rules (one at a time or batch)
cm playbook add "Your rule content" --category "debugging"

# 5. Mark session as processed
cm onboard mark-done /path/to/session.jsonl
```

Before starting complex tasks, retrieve relevant context:

```bash
cm context "<task description>" --json
```

This returns:
- **relevantBullets**: Rules that may help with your task
- **antiPatterns**: Pitfalls to avoid
- **historySnippets**: Past sessions that solved similar problems
- **suggestedCassQueries**: Searches for deeper investigation

### Protocol

1. **START**: Run `cm context "<task>" --json` before non-trivial work
2. **WORK**: Reference rule IDs when following them (e.g., "Following b-8f3a2c...")
3. **FEEDBACK**: Leave inline comments when rules help/hurt
4. **END**: Just finish your work. Learning happens automatically.

---

## UBS Quick Reference for AI Agents

UBS stands for "Ultimate Bug Scanner": **The AI Coding Agent's Secret Weapon: Flagging Likely Bugs for Fixing Early On**

**Golden Rule:** `ubs <changed-files>` before every commit. Exit 0 = safe. Exit >0 = fix & re-run.

**For Shell Scripts:**
```bash
ubs src/act_runner.sh scripts/toolchain_check.sh  # Specific files (< 1s) — USE THIS
ubs $(git diff --name-only --cached)              # Staged files — before commit
ubs --only=bash scripts/                          # Language filter
ubs --ci --fail-on-warning .                      # CI mode — before PR
ubs .                                             # Whole project
```

**Output Format:**
```
Warning  Category (N errors)
    file.sh:42:5 – Issue description
    Suggested fix
Exit code: 1
```
Parse: `file:line:col` -> location | Suggested fix -> how to fix | Exit 0/1 -> pass/fail

**Fix Workflow:**
1. Read finding -> category + fix suggestion
2. Navigate `file:line:col` -> view context
3. Verify real issue (not false positive)
4. Fix root cause (not symptom)
5. Re-run `ubs <file>` -> exit 0
6. Commit

**Speed Critical:** Scope to changed files. `ubs src/act_runner.sh` (< 1s) vs `ubs .` (30s). Never full scan for small edits.

**Anti-Patterns:**
- Do not ignore findings -> Investigate each
- Do not full scan per edit -> Scope to file
- Do not fix symptom -> Fix root cause
