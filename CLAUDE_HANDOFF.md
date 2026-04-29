# Claude Handoff

## Summary

- Imported the upstream `openai/symphony` repository into `/Users/andrew/Documents/Symphonium`.
- Set up the Elixir implementation under `elixir/` according to the upstream README.
- Installed `mise` with Homebrew, then installed pinned Erlang/OTP 28 and Elixir 1.19.5 from `elixir/mise.toml`.
- Saved the Linear API key in `elixir/.env`; the file is ignored and should not be printed or committed.
- Added `elixir/.env.example` and updated `elixir/.gitignore` so the real `.env` remains ignored while the example is trackable.
- Updated `elixir/README.md` to show loading `.env` and the required guardrails acknowledgement flag.
- Stabilized timing-sensitive tests in:
  - `elixir/test/symphony_elixir/core_test.exs`
  - `elixir/test/symphony_elixir/ssh_test.exs`

## Verification

From `/Users/andrew/Documents/Symphonium/elixir`:

```bash
set -a
source .env
set +a
mise exec -- mix run -e 'case SymphonyElixir.Config.validate!() do :ok -> IO.puts("config ok"); other -> IO.inspect(other); System.halt(1) end'
```

Result: `config ok`

```bash
mise exec -- make all
```

Result: passed. Coverage reported `230 tests, 0 failures, 2 skipped`; dialyzer reported `Total errors: 0`.

## Re-Verification Focus

- Confirm `elixir/.env` is still ignored before any commit.
- Re-run `mise exec -- make all` after pulling or changing upstream files.
- If testing the actual service, run from `elixir/` only after intentionally loading `.env`.

## 2026-04-28 Runtime Fix Follow-Up

- AC-7 initially failed with `:response_timeout` because Codex app-server did not initialize cleanly in the fresh workspace trust context.
- A later retry failed with `{:port_exit, 0}` after Codex did real turn work, because the installed Codex CLI exited cleanly without the older `turn/completed` marker.
- Fixes now include dynamic workspace trust in `elixir/WORKFLOW.md`, clean Codex port-exit handling, closed-port send hardening, and a Linear schema guard telling agents not to query `Issue.links`.
- `mise exec -- make all` passed with `232 tests, 0 failures, 2 skipped` and dialyzer `Total errors: 0`.
- Live config validation returned `config ok`.
- The dashboard is running at `http://localhost:4000/` in detached `screen` session `symphonium`.
- In-app browser verification loaded `http://localhost:4000/` with title `Symphony Observability`.
- A fresh post-restart log scan found no `:response_timeout`, `port_exit`, or `Issue.links` GraphQL errors.
- See `ISSUES_LOG.md` for the incident log and fixes.

## 2026-04-29 App Rerun

- Rebuilt the escript from `/Users/andrew/Documents/Symphonium/elixir` with `set -a; source .env; set +a; mise exec -- mix build`.
- Restarted the dashboard in detached `screen` session `symphonium`.
- Startup cleanup hooks completed, then the endpoint bound at `127.0.0.1:4000`.
- Health check: `curl http://localhost:4000/api/v1/state` returned successfully with `running: 1` and active issue `AC-14`.
- In-app browser reload verified `http://localhost:4000/` with title `Symphony Observability` and dashboard content present.
- Recent log scan showed only expected startup lines for `SymphonyElixirWeb.Endpoint` on port 4000; no recent `:response_timeout`, `Issue.links`, or Linear GraphQL failure lines were present.

## 2026-04-29 Orchestrum Rename and Publish Handoff

- Renamed product-facing docs, CLI output, dashboard labels, default workspace/log paths, and the escript from Symphony to Orchestrum.
- Configured `elixir/WORKFLOW.md` so future orchestrator task workspaces clone `https://github.com/ac-opensource/Orchestrum` and agents push task branches/PRs to that clone's `origin`.
- Updated workspace cleanup to close PRs in `ac-opensource/Orchestrum`.
- Preserved the internal Elixir module/OTP app namespace (`SymphonyElixir` / `:symphony_elixir`) to keep the rename scoped and low-risk.
- Validation: `mise exec -- make all` passed from `elixir/` with 242 tests, 0 failures, 2 skipped, 100% coverage, and Dialyzer `Total errors: 0`.
- Re-verification focus: confirm future task workspaces have `origin` set to `https://github.com/ac-opensource/Orchestrum` before pushing.
