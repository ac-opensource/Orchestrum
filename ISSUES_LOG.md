# Issues Log

## 2026-04-28 - Symphony AC-7 agent startup and completion failures

### Symptoms

- Dashboard showed AC-7 repeatedly retrying with `:response_timeout`.
- After the workspace was trusted manually, the next retry reached a Codex session but failed with `{:port_exit, 0}`.

### Findings

- `:response_timeout` happened before a turn started. Codex app-server emitted a project trust warning for `/Users/andrew/code/symphony-workspaces/AC-7/.codex` and never produced the expected initialize response in that run.
- Symphony workspaces are ephemeral, so a one-off trust entry for AC-7 is not enough for later tickets.
- Installed Codex CLI `0.125.0` can exit with status `0` after turn activity without emitting the older `turn/completed` event that Symphony was waiting for.
- Detached dashboard launches from Codex need a real process session; plain background jobs from the command runner are reaped. A detached `screen` session keeps the server alive.
- Later fresh runs exposed agent-generated Linear GraphQL errors: `Cannot query field "links" on type "Issue"`. Live schema introspection confirmed `Issue` exposes `attachments`, `relations`, and `inverseRelations`, but not `links`.

### Fixes

- Updated `elixir/WORKFLOW.md` so the Codex command trusts the current workspace dynamically with:
  `--config "projects.\"$PWD\".trust_level=\"trusted\""`
- Updated `SymphonyElixir.Codex.AppServer` to treat `exit_status: 0` after observed turn activity as a completed turn.
- Hardened app-server writes so a closed Codex port returns an error tuple instead of crashing the runner with `ArgumentError`.
- Updated `SymphonyElixir.AgentRunner` to return control to the orchestrator when a clean app-server exit completed a turn, allowing the orchestrator to schedule the next continuation cleanly.
- Added regression coverage for clean app-server exit after turn activity and clean exit before any activity.
- Updated `elixir/WORKFLOW.md` and the `linear_graphql` tool description to tell agents not to query `Issue.links`; use `attachments`, `relations`, and `inverseRelations` instead.
- Isolated timing-sensitive tests from live Linear polling and relaxed retry-backoff assertions to compare due timestamps instead of elapsed wall-clock time after scheduler delays.

### Validation

- `mise exec -- mix test test/symphony_elixir/app_server_test.exs`: passed, 18 tests.
- `mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/core_test.exs:951`: passed, 16 tests.
- `mise exec -- make all`: passed. Coverage reported `232 tests, 0 failures, 2 skipped`; dialyzer reported `Total errors: 0`.
- Config validation with the live `.env`: `config ok`.
- Restarted the dashboard at `http://localhost:4000/` in detached `screen` session `symphonium`; `/api/v1/state` responded.
- In-app browser verification loaded `http://localhost:4000/` with title `Symphony Observability`.
- Fresh 35-second log scan after restart showed no `:response_timeout`, `port_exit`, or `Issue.links` GraphQL errors.
