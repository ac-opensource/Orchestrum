defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixir.Tracker.Unsupported

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      recipient = Application.get_env(:symphony_elixir, :fake_linear_recipient, self())
      send(recipient, {:graphql_called, query, variables})

      case Application.get_env(:symphony_elixir, :fake_linear_graphql_results) do
        [result | rest] ->
          Application.put_env(:symphony_elixir, :fake_linear_graphql_results, rest)
          result

        _ ->
          application_result = Application.get_env(:symphony_elixir, :fake_linear_graphql_result)

          if is_nil(application_result) do
            process_graphql_result()
          else
            application_result
          end
      end
    end

    defp process_graphql_result do
      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

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

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end

    def handle_call({:control, request}, _from, state) do
      {:reply, state |> Keyword.get(:controls, %{}) |> Map.get(request, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :fake_linear_graphql_result)
      Application.delete_env(:symphony_elixir, :fake_linear_graphql_results)
      Application.delete_env(:symphony_elixir, :fake_linear_recipient)

      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])

    assert {:error, {:unsupported_tracker_write, "memory"}} =
             SymphonyElixir.Tracker.create_comment("issue-1", "comment")

    assert {:error, {:unsupported_tracker_write, "memory"}} =
             SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")

    assert {:error, {:unsupported_tracker_write, "memory"}} = Memory.create_comment("issue-1", "quiet")
    assert {:error, {:unsupported_tracker_write, "memory"}} = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "tracker reports explicit unsupported adapter errors" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "jira")

    assert SymphonyElixir.Tracker.adapter() == Unsupported
    assert {:error, {:unsupported_tracker_kind, "jira"}} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:error, {:unsupported_tracker_kind, "jira"}} = SymphonyElixir.Tracker.fetch_issues_by_states(["Todo"])
    assert {:error, {:unsupported_tracker_kind, "jira"}} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert {:error, {:unsupported_tracker_write, "jira"}} = SymphonyElixir.Tracker.create_comment("issue-1", "body")
    assert {:error, {:unsupported_tracker_write, "jira"}} = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: nil)
    assert {:error, {:unsupported_tracker_kind, "unknown"}} = Unsupported.fetch_candidate_issues()
    assert {:error, {:unsupported_tracker_write, "unknown"}} = Unsupported.create_comment("issue-1", "body")
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload["counts"] == %{"running" => 1, "retrying" => 1}
    assert [%{"tracker_project_slug" => "project"}] = state_payload["projects"]

    assert state_payload["polling"] == %{
             "checking?" => false,
             "paused?" => false,
             "next_poll_in_ms" => 25_000,
             "poll_interval_ms" => 30_000
           }

    assert state_payload["controls"] == %{
             "polling_paused" => false,
             "paused_projects" => [],
             "pending_dispatch_projects" => []
           }

    assert state_payload["claimed"] == []

    assert [
             %{
               "issue_id" => "issue-http",
               "issue_identifier" => "MT-HTTP",
               "state" => "In Progress",
               "project" => nil,
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             }
           ] = state_payload["running"]

    assert [
             %{
               "issue_id" => "issue-retry",
               "issue_identifier" => "MT-RETRY",
               "attempt" => 2,
               "project" => nil,
               "error" => "boom",
               "worker_host" => nil,
               "workspace_path" => nil
             }
           ] = state_payload["retrying"]

    assert state_payload["codex_totals"] == %{
             "input_tokens" => 4,
             "output_tokens" => 8,
             "total_tokens" => 12,
             "seconds_running" => 42.5
           }

    assert state_payload["rate_limits"] == %{"primary" => %{"remaining" => 11}}

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "project" => nil,
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "project" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix control api reports success rejected unsupported and unavailable states" do
    orchestrator_name = Module.concat(__MODULE__, :ControlApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        controls: %{
          {:pause_polling, :global} => %{
            ok: true,
            action: "pause_polling",
            status: "paused",
            message: "Global polling paused",
            target: %{scope: "global"},
            result_id: "ctrl-api-pause",
            requested_at: DateTime.utc_now()
          },
          {:cancel_run, "MT-HTTP"} => %{
            ok: false,
            action: "cancel_run",
            status: "rejected",
            code: "issue_not_running",
            message: "Issue does not have an active run",
            target: %{issue_identifier: "MT-HTTP"},
            result_id: "ctrl-api-reject",
            requested_at: DateTime.utc_now()
          }
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    pause_payload = json_response(post(build_conn(), "/api/v1/control/polling/pause", %{}), 200)
    assert pause_payload["ok"] == true
    assert pause_payload["status"] == "paused"
    assert pause_payload["result_id"] == "ctrl-api-pause"
    assert is_binary(pause_payload["requested_at"])

    rejected_payload =
      json_response(post(build_conn(), "/api/v1/control/issues/MT-HTTP/cancel", %{}), 409)

    assert rejected_payload["ok"] == false
    assert rejected_payload["code"] == "issue_not_running"
    assert rejected_payload["result_id"] == "ctrl-api-reject"

    assert json_response(post(build_conn(), "/api/v1/control/projects/project/nope", %{}), 422) ==
             %{
               "error" => %{
                 "code" => "unsupported_action",
                 "message" => "Unsupported orchestrator control"
               }
             }
  end

  test "phoenix control api reports unavailable orchestrator state" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingControlOrchestrator),
      snapshot_timeout_ms: 5
    )

    assert json_response(post(build_conn(), "/api/v1/control/polling/pause", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix control api rejects unauthorized token-protected control requests" do
    orchestrator_name = Module.concat(__MODULE__, :AuthorizedControlApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        controls: %{
          {:pause_polling, :global} => %{
            ok: true,
            action: "pause_polling",
            status: "paused",
            message: "Global polling paused",
            target: %{scope: "global"},
            result_id: "ctrl-authorized",
            requested_at: DateTime.utc_now()
          }
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50, control_token: "secret")

    assert json_response(post(build_conn(), "/api/v1/control/polling/pause", %{}), 401) ==
             %{"error" => %{"code" => "unauthorized", "message" => "Control token is invalid"}}

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("x-orchestrum-control-token", "secret")
      |> post("/api/v1/control/polling/pause", %{})

    assert %{"ok" => true, "result_id" => "ctrl-authorized"} = json_response(conn, 200)
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "ticket-reply-form"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    assert html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"
    assert html =~ "Pause polling"
    assert html =~ "Dispatch now"
    assert html =~ "Stop"
    assert html =~ "Retry now"
    assert html =~ "Clear"
    assert html =~ "data-confirm="
    assert html =~ "phx-disable-with=\"Working\""

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview sends controls and renders result messages" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardControlOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        controls: %{
          {:pause_polling, :global} => %{
            ok: true,
            action: "pause_polling",
            status: "paused",
            message: "Global polling paused",
            target: %{scope: "global"},
            result_id: "ctrl-live-pause",
            requested_at: DateTime.utc_now()
          },
          {:cancel_run, "MT-HTTP"} => %{
            ok: false,
            action: "cancel_run",
            status: "rejected",
            code: "issue_not_running",
            message: "Issue does not have an active run",
            target: %{issue_identifier: "MT-HTTP"},
            result_id: "ctrl-live-reject",
            requested_at: DateTime.utc_now()
          }
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "data-confirm=\"Pause global polling?\""
    assert html =~ "phx-disable-with=\"Working\""

    html =
      view
      |> element("button[phx-value-action=\"pause_global\"]")
      |> render_click()

    assert html =~ "Global polling paused (ctrl-live-pause)"

    html =
      view
      |> element(~s(button[phx-value-action="cancel_run"][phx-value-target="MT-HTTP"]))
      |> render_click()

    assert html =~ "Issue does not have an active run (ctrl-live-reject)"
  end

  test "dashboard liveview sends ticket replies for human review sessions" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, :fake_linear_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :DashboardTicketReplyOrchestrator)

    snapshot =
      static_snapshot()
      |> put_in([:running, Access.at(0), :state], "Need Human Review")

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "ticket-reply-form-issue-http"
    assert html =~ "Reply to MT-HTTP"

    html =
      view
      |> form("#ticket-reply-form-issue-http", %{"body" => "   "})
      |> render_submit()

    assert html =~ "Reply body is required."

    Application.put_env(
      :symphony_elixir,
      :fake_linear_graphql_result,
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    html =
      view
      |> form("#ticket-reply-form-issue-http", %{"body" => "  Human reply from dashboard  "})
      |> render_submit()

    assert html =~ "Reply sent"
    assert_receive {:graphql_called, create_comment_query, %{body: "Human reply from dashboard", issueId: "issue-http"}}
    assert create_comment_query =~ "commentCreate"
  end

  test "dashboard liveview adds projects to workflow config" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardProjectOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Projects"
    assert html =~ "aria-label=\"Add project\""
    assert html =~ "Git identity"
    assert html =~ "Agent instructions"

    html =
      view
      |> element("button[aria-label=\"Add project\"]")
      |> render_click()

    assert html =~ "Linear project slug"
    assert html =~ "Local directory"
    assert html =~ "Remote repository"
    assert html =~ "Git name"

    html =
      view
      |> form("#add-project-form", project: %{"name" => "Wallet Android", "project_slug" => ""})
      |> render_submit()

    assert html =~ "Linear project slug is required."
    assert Enum.map(Config.project_configs(), & &1.tracker_project_slug) == ["project"]

    html =
      view
      |> form("#add-project-form",
        project: %{
          "name" => "Wallet Android",
          "project_slug" => "wallet-android",
          "workspace_root" => "/tmp/wallet-workspaces",
          "repository_path" => "https://github.com/ac-opensource/wallet-android",
          "git_name" => "Wallet Bot",
          "git_username" => "wallet-bot",
          "git_email" => "wallet-bot@example.com"
        }
      )
      |> render_submit()

    assert html =~ "Wallet Android"
    assert html =~ "wallet-android"
    assert html =~ "/tmp/wallet-workspaces"
    assert html =~ "https://github.com/ac-opensource/wallet-android"
    assert html =~ "name: Wallet Bot"
    assert html =~ "username: wallet-bot"
    assert html =~ "email: wallet-bot@example.com"
    assert html =~ "Wallet Android added"

    assert Enum.map(Config.project_configs(), & &1.tracker_project_slug) == ["project", "wallet-android"]
    assert Enum.map(Config.project_configs(), & &1.name) == ["project", "Wallet Android"]

    assert {:ok, %{config: config}} = Workflow.load(Workflow.workflow_file_path())

    assert [
             %{"tracker" => %{"project_slug" => "project"}},
             %{
               "id" => "wallet-android",
               "name" => "Wallet Android",
               "tracker" => %{"project_slug" => "wallet-android"},
               "workspace" => %{"root" => "/tmp/wallet-workspaces"},
               "repository" => %{"path" => "https://github.com/ac-opensource/wallet-android"},
               "git" => %{
                 "name" => "Wallet Bot",
                 "username" => "wallet-bot",
                 "email" => "wallet-bot@example.com"
               }
             }
           ] = config["projects"]

    html =
      view
      |> element("button[aria-label=\"Add project\"]")
      |> render_click()

    assert html =~ "Linear project slug"

    html =
      view
      |> form("#add-project-form",
        project: %{"name" => "Wallet Android", "project_slug" => "wallet-android"}
      )
      |> render_submit()

    assert html =~ "Project is already configured."
    assert Enum.map(Config.project_configs(), & &1.tracker_project_slug) == ["project", "wallet-android"]
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
    assert html =~ "disabled"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
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

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}},
      polling: %{checking?: false, next_poll_in_ms: 25_000, poll_interval_ms: 30_000}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
