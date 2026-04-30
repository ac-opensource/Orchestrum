defmodule SymphonyElixir.OrchestratorControlTest do
  use SymphonyElixir.TestSupport

  test "control_action queues dispatch, reports unavailable controls, clears retries, and releases stale claims" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    orchestrator_name = Module.concat(__MODULE__, :ControlOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.new(["issue-retry", "issue-stale"]),
          retry_attempts: %{
            "issue-retry" => %{
              attempt: 2,
              timer_ref: nil,
              retry_token: make_ref(),
              due_at_ms: System.monotonic_time(:millisecond) + 60_000,
              identifier: "AC-RETRY",
              error: "boom"
            }
          }
      }
    end)

    assert {:ok, %{action: "dispatch-now", queued: true, operations: ["poll", "reconcile"]}} =
             Orchestrator.control_action(orchestrator_name, "dispatch-now", %{})

    assert {:error, {:control_not_implemented, "pause"}} =
             Orchestrator.control_action(orchestrator_name, "pause", %{})

    assert {:ok, %{action: "clear-retry", issue_id: "issue-retry", status: "retry_cleared"}} =
             Orchestrator.control_action(orchestrator_name, "clear-retry", %{"issue_id" => "issue-retry"})

    state = :sys.get_state(pid)
    refute Map.has_key?(state.retry_attempts, "issue-retry")
    refute MapSet.member?(state.claimed, "issue-retry")

    assert {:ok, %{action: "release-claim", issue_id: "issue-stale", status: "claim_released"}} =
             Orchestrator.control_action(orchestrator_name, "release-claim", %{"issue_id" => "issue-stale"})

    state = :sys.get_state(pid)
    refute MapSet.member?(state.claimed, "issue-stale")
  end
end
