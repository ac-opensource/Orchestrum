defmodule SymphonyElixirWeb.PresenterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.Presenter

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end
  end

  test "task board payload maps tracker issues with run and retry overlays" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      issue("issue-run", "AC-1", "In Progress"),
      issue("issue-retry", "AC-2", "Todo"),
      issue("issue-idle", "AC-3", "Todo")
    ])

    orchestrator_name = Module.concat(__MODULE__, :TaskBoardOrchestrator)

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator_name,
       snapshot: %{
         running: [running_entry("issue-run", "AC-1")],
         retrying: [retry_entry("issue-retry", "AC-2")],
         codex_totals: %{},
         rate_limits: nil,
         polling: %{}
       }}
    )

    assert {:ok, payload} = Presenter.task_board_payload(orchestrator_name, 50, %{"limit" => "2"})

    assert payload.pagination == %{limit: 2, after: 0, next_after: 2, total: 3}
    assert payload.filters.states == ["Todo", "In Progress"]
    assert [%{tracker_project_slug: "project"}] = payload.projects

    assert [
             %{
               issue: %{id: "issue-run", identifier: "AC-1", title: "Issue AC-1"},
               runtime: %{status: "running", running: %{session_id: "thread-AC-1"}, retry: nil}
             },
             %{
               issue: %{id: "issue-retry", identifier: "AC-2"},
               runtime: %{status: "retrying", running: nil, retry: %{attempt: 2, error: "boom"}}
             }
           ] = payload.tasks
  end

  test "task board payload applies project filters and reports invalid pagination" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue("issue-run", "AC-1", "In Progress")])

    orchestrator_name = Module.concat(__MODULE__, :FilteredTaskBoardOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: %{running: [], retrying: []}})

    assert {:ok, payload} =
             Presenter.task_board_payload(orchestrator_name, 50, %{"project_slug" => "missing"})

    assert payload.pagination.total == 0
    assert payload.tasks == []

    assert {:error, {:invalid_request, "limit must be a positive integer"}} =
             Presenter.task_board_payload(orchestrator_name, 50, %{"limit" => "nope"})
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Issue #{identifier}",
      description: "Description #{identifier}",
      priority: 2,
      state: state,
      branch_name: "feature/#{String.downcase(identifier)}",
      url: "https://linear.app/ac-bitcoin/issue/#{identifier}",
      assignee_id: "user-1",
      project: %{id: "linear-project", name: "Project", slug: "project"},
      blocked_by: [%{id: "blocker", identifier: "AC-0", state: "In Progress"}],
      labels: ["feature"],
      assigned_to_worker: true,
      created_at: ~U[2026-04-30 00:00:00Z],
      updated_at: ~U[2026-04-30 00:05:00Z]
    }
  end

  defp running_entry(issue_id, identifier) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      state: "In Progress",
      project: %{id: "linear-project", name: "Project", slug: "project"},
      worker_host: "worker-1",
      workspace_path: "/tmp/#{identifier}",
      session_id: "thread-#{identifier}",
      turn_count: 3,
      last_codex_event: :notification,
      last_codex_message: "Working",
      started_at: ~U[2026-04-30 00:00:00Z],
      last_codex_timestamp: ~U[2026-04-30 00:01:00Z],
      codex_input_tokens: 10,
      codex_output_tokens: 5,
      codex_total_tokens: 15
    }
  end

  defp retry_entry(issue_id, identifier) do
    %{
      issue_id: issue_id,
      identifier: identifier,
      attempt: 2,
      due_in_ms: 1_000,
      error: "boom",
      project: %{id: "linear-project", name: "Project", slug: "project"},
      worker_host: "worker-1",
      workspace_path: "/tmp/#{identifier}"
    }
  end
end
