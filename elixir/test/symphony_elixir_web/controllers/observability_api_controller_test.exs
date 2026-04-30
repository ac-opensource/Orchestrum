defmodule SymphonyElixirWeb.ObservabilityApiControllerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.get(state, :snapshot, %{running: [], retrying: []}), state}
    end

    def handle_call({:control_action, action, params}, _from, state) do
      send(Keyword.fetch!(state, :recipient), {:control_action, action, params})
      reply = control_reply(Keyword.get(state, :control_reply), action, params)
      {:reply, reply, state}
    end

    defp control_reply(fun, action, params) when is_function(fun, 2), do: fun.(action, params)
    defp control_reply(nil, action, _params), do: {:ok, %{status: "accepted", action: action}}
    defp control_reply(reply, _action, _params), do: reply
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "task board endpoint returns tracker data and enforces methods" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-1",
        identifier: "AC-1",
        title: "Task one",
        state: "In Progress",
        project: %{id: "linear-project", name: "Project", slug: "project"}
      }
    ])

    orchestrator_name = Module.concat(__MODULE__, :TaskBoardControllerOrchestrator)

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator_name,
       recipient: self(),
       snapshot: %{
         running: [
           %{
             issue_id: "issue-1",
             identifier: "AC-1",
             state: "In Progress",
             session_id: "thread-1",
             turn_count: 1,
             last_codex_message: nil,
             last_codex_timestamp: nil,
             last_codex_event: nil,
             codex_input_tokens: 1,
             codex_output_tokens: 2,
             codex_total_tokens: 3,
             started_at: ~U[2026-04-30 00:00:00Z]
           }
         ],
         retrying: []
       }}
    )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    response = json_response(get(build_conn(), "/api/v1/task-board", %{"limit" => "1"}), 200)

    assert response["pagination"] == %{"after" => 0, "limit" => 1, "next_after" => nil, "total" => 1}
    assert [%{"issue" => %{"identifier" => "AC-1"}, "runtime" => %{"status" => "running"}}] = response["tasks"]

    assert json_response(post(build_conn(), "/api/v1/task-board", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}
  end

  test "control endpoint routes all declared actions through explicit success envelopes" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    orchestrator_name = Module.concat(__MODULE__, :ControlControllerOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, recipient: self()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    for action <- ["pause", "resume", "dispatch-now", "stop", "cancel", "retry-now", "clear-retry", "release-claim"] do
      response = json_response(post(build_conn(), "/api/v1/control/#{action}", %{"issue_id" => "issue-1"}), 202)

      assert response["ok"] == true
      assert response["action"] == action
      assert response["result"]["status"] == "accepted"
      assert_received {:control_action, ^action, %{"issue_id" => "issue-1"}}
    end
  end

  test "control endpoint handles unsupported methods, invalid requests, and unsupported actions" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    invalid_orchestrator = Module.concat(__MODULE__, :InvalidControlOrchestrator)

    start_supervised!(
      {StaticOrchestrator,
       name: invalid_orchestrator,
       recipient: self(),
       control_reply: fn
         "unknown", _params -> {:error, {:unsupported_control_action, "unknown"}}
         _action, _params -> {:error, {:invalid_control_request, "issue_id or issue_identifier is required"}}
       end}
    )

    start_test_endpoint(orchestrator: invalid_orchestrator, snapshot_timeout_ms: 50)

    assert json_response(get(build_conn(), "/api/v1/control/dispatch-now"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    invalid_response = json_response(post(build_conn(), "/api/v1/control/clear-retry", %{}), 400)

    assert invalid_response == %{
             "ok" => false,
             "action" => "clear-retry",
             "error" => %{
               "code" => "invalid_control_request",
               "message" => "issue_id or issue_identifier is required"
             }
           }

    unsupported_response = json_response(post(build_conn(), "/api/v1/control/unknown", %{}), 400)

    assert get_in(unsupported_response, ["error", "code"]) == "unsupported_control_action"
  end

  test "control endpoint reports unavailable orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :MissingOrchestrator), snapshot_timeout_ms: 50)

    unavailable_response = json_response(post(build_conn(), "/api/v1/control/dispatch-now", %{}), 503)

    assert unavailable_response == %{
             "ok" => false,
             "action" => "dispatch-now",
             "error" => %{
               "code" => "orchestrator_unavailable",
               "message" => "Orchestrator is unavailable"
             }
           }
  end

  test "task board endpoint returns tracker errors explicitly" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    orchestrator_name = Module.concat(__MODULE__, :TrackerErrorOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, recipient: self()})
    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    response = json_response(get(build_conn(), "/api/v1/task-board"), 502)

    assert response["error"]["code"] == "tracker_error"
    assert response["error"]["details"]["reason"] =~ "unsupported_tracker_kind"
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
