# Orchestrum Elixir

This directory contains the current Elixir/OTP implementation of Orchestrum, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Orchestrum Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Orchestrum Elixir screenshot](../.github/media/ac31-command-center-desktop.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Orchestrum serves client-side tracker tools. `linear_graphql` is available
for raw Linear reads and verification, while `tracker_create_comment` and
`tracker_update_issue_state` route comments and state changes through the configured tracker adapter.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Orchestrum stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Orchestrum's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/ac-opensource/Orchestrum
cd Orchestrum/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/orchestrum ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/orchestrum` when starting the service:

```bash
./bin/orchestrum /path/to/custom/WORKFLOW.md
```

If no path is passed, Orchestrum defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Orchestrum to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Orchestrum passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Orchestrum validation.
- `agent.max_turns` caps how many back-to-back Codex turns Orchestrum will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Orchestrum uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- For multiple projects, define a top-level `projects` list. Each project inherits top-level
  `tracker` and `workspace` defaults and may override `tracker.project_slug`, state lists,
  `workspace.root`, `repository.path`, and `git` identity settings.
- `repository.path` on a project may be a local path or remote Git URL. Orchestrum clones that
  repository into a newly created workspace before running `hooks.after_create`.
- `git.name`, `git.email`, and `git.username` on a project are applied to the prepared Git
  workspace as `user.name`, `user.email`, and `credential.username` before `hooks.after_create`
  runs.
- When a prepared project workspace contains `AGENTS.md`, `AGENT.md`, `agents.md`, or `agent.md` at
  its root, Orchestrum prepends those project-local instructions to the first Codex turn prompt.
- The dashboard Projects panel renders each configured project's local directory, repository, Git
  identity, and agent instruction status. Its add-project form persists the same settings back to
  `WORKFLOW.md`.
- `orchestrator.state_path` stores retry/session metadata as local JSON. When omitted, Orchestrum
  writes `orchestrator_state.json` next to the configured log file.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $ORCHESTRUM_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Orchestrum does not boot.
- If a later reload fails, Orchestrum keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.enabled: true` starts the optional Phoenix LiveView dashboard and JSON API using
  `server.port` or port `4000` when no port is set. CLI `--port` overrides workflow server config.
- `observability.snapshot_timeout_ms` controls dashboard/API snapshot calls.
- The dashboard/API are available at `/`, dashboard surface routes such as `/tasks`, `/runs`,
  `/projects`, `/controls`, `/settings`, and `/diagnostics`, run detail routes such as
  `/runs/<issue_identifier>`, plus `/api/v1/state`, `/api/v1/task-board`,
  `/api/v1/<issue_identifier>`, `/api/v1/refresh`, `/api/v1/control/<control_action>`, and
  explicit `/api/v1/control/*` routes.
  Control endpoints are POST-only side effects:
  `/api/v1/control/polling/{pause,resume}`,
  `/api/v1/control/projects/<project_id>/{pause,resume,dispatch}`, and
  `/api/v1/control/issues/<issue_identifier>/{cancel,retry,clear_retry,release_claim}`.
  Task-board responses include configured project metadata, tracker issue fields, applied
  filters, limit/offset pagination, and running/retry overlay state. Control responses use explicit
  success/error envelopes for `pause`, `resume`, `dispatch-now`, `stop`, `cancel`, `retry-now`,
  `clear-retry`, and `release-claim`.
  If Phoenix endpoint config includes `control_token`, requests must send it as
  `x-orchestrum-control-token`.

## Web dashboard

The operational dashboard runs on a minimal Phoenix stack:

- LiveView for the dashboard shell at `/` with deep-linkable operator surfaces for Overview, Tasks,
  Runs, Projects, Controls, Settings, and Diagnostics
- JSON API for operational debugging under `/api/v1/*`
- Project/workspace/repository inventory, dashboard project creation, MCP server status visibility,
  next-poll visibility, manual refresh, tracker-backed replies for tickets needing human review,
  and confirmed run/queue controls
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Orchestrum to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `ORCHESTRUM_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `ORCHESTRUM_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `ORCHESTRUM_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Orchestrum can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `ORCHESTRUM_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Orchestrum repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
