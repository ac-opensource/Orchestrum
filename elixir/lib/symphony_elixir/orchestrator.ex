defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.Persistence

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @persistence_version 1
  @event_history_limit 50
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    state = restore_persisted_state(state)
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

              state
              |> complete_issue(issue_id)
              |> schedule_issue_retry(issue_id, 1, %{
                identifier: running_entry.identifier,
                delay_type: :continuation,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                project: Map.get(running_entry, :project),
                retry_history: Map.get(running_entry, :retry_history, []),
                branch_name: get_in(running_entry, [:issue, Access.key(:branch_name)]),
                issue_url: get_in(running_entry, [:issue, Access.key(:url)])
              })

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                project: Map.get(running_entry, :project),
                retry_history: Map.get(running_entry, :retry_history, []),
                branch_name: get_in(running_entry, [:issue, Access.key(:branch_name)]),
                issue_url: get_in(running_entry, [:issue, Access.key(:url)])
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        state = %{state | running: Map.put(running, issue_id, updated_running_entry)}

        notify_dashboard()
        {:noreply, persist_state(state)}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> then(&%{&1 | running: Map.put(running, issue_id, updated_running_entry)})

        notify_dashboard()
        {:noreply, persist_state(state)}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- safe_fetch_candidate_issues(),
         true <- available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(issue), terminal_state_set(issue))
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set(issue))
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    active_states = active_state_set(issue, active_states)
    terminal_states = terminal_state_set(issue, terminal_states)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }
        |> persist_state()

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    cond do
      restored_unmonitored_session?(running_entry) ->
        restart_restored_unmonitored_issue(state, issue_id, running_entry)

      is_integer(elapsed_ms) and elapsed_ms > timeout_ms ->
        identifier = Map.get(running_entry, :identifier, issue_id)
        session_id = running_entry_session_id(running_entry)

        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: identifier,
          error: "stalled for #{elapsed_ms}ms without codex activity",
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path),
          session_id: Map.get(running_entry, :session_id),
          project: Map.get(running_entry, :project),
          retry_history: Map.get(running_entry, :retry_history, []),
          branch_name: get_in(running_entry, [:issue, Access.key(:branch_name)]),
          issue_url: get_in(running_entry, [:issue, Access.key(:url)])
        })

      true ->
        state
    end
  end

  defp restored_unmonitored_session?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :restored) == true and
      is_nil(Map.get(running_entry, :pid)) and
      is_nil(Map.get(running_entry, :ref))
  end

  defp restored_unmonitored_session?(_running_entry), do: false

  defp restart_restored_unmonitored_issue(state, issue_id, running_entry) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)

    Logger.warning("Issue restored without monitorable worker: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id}; reconciling with retry backoff")

    next_attempt = next_retry_attempt_from_running(running_entry)

    state
    |> terminate_running_issue(issue_id, false)
    |> schedule_issue_retry(issue_id, next_attempt, %{
      identifier: identifier,
      error: "orchestrator restarted before worker completion",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: Map.get(running_entry, :session_id),
      project: Map.get(running_entry, :project),
      retry_history: Map.get(running_entry, :retry_history, []),
      branch_name: get_in(running_entry, [:issue, Access.key(:branch_name)]),
      issue_url: get_in(running_entry, [:issue, Access.key(:url)])
    })
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      issue_active_states = active_state_set(issue, active_states)
      issue_terminal_states = terminal_state_set(issue, terminal_states)

      if should_dispatch_issue?(issue, state_acc, issue_active_states, issue_terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.project_configs()
    |> Enum.flat_map(& &1.terminal_states)
    |> state_name_set()
  end

  defp active_state_set do
    Config.project_configs()
    |> Enum.flat_map(& &1.active_states)
    |> state_name_set()
  end

  defp terminal_state_set(%Issue{} = issue), do: state_name_set(Config.project_config_for_issue(issue).terminal_states)
  defp terminal_state_set(_issue), do: terminal_state_set()

  defp terminal_state_set(%Issue{} = issue, _fallback), do: terminal_state_set(issue)
  defp terminal_state_set(_issue, fallback), do: fallback

  defp active_state_set(%Issue{} = issue), do: state_name_set(Config.project_config_for_issue(issue).active_states)

  defp active_state_set(%Issue{} = issue, _fallback), do: active_state_set(issue)
  defp active_state_set(_issue, fallback), do: fallback

  defp state_name_set(state_names) do
    state_names
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil, retry_metadata \\ %{}) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set(issue)) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, retry_metadata)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, retry_metadata) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, retry_metadata)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, retry_metadata) do
    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(issue, recipient, attempt: attempt, worker_host: worker_host)
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            project: issue.project,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            current_turn_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            event_history: [],
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            retry_history: retry_metadata[:retry_history] || [],
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }
        |> persist_state()

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host,
          project: issue.project,
          retry_history: retry_metadata[:retry_history] || [],
          branch_name: issue.branch_name,
          issue_url: issue.url
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
    |> persist_state()
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    due_at_wall_ms = System.system_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    project = pick_retry_project(previous_retry, metadata)
    session_id = pick_retry_session_id(previous_retry, metadata)
    branch_name = pick_retry_branch_name(previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)

    retry_history =
      append_retry_history(Map.get(previous_retry, :retry_history) || metadata[:retry_history] || [], %{
        attempt: next_attempt,
        due_at_wall_ms: due_at_wall_ms,
        delay_ms: delay_ms,
        delay_type: metadata[:delay_type],
        error: error
      })

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            due_at_wall_ms: due_at_wall_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            project: project,
            session_id: session_id,
            branch_name: branch_name,
            issue_url: issue_url,
            retry_history: retry_history
          })
    }
    |> persist_state()
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          session_id: Map.get(retry_entry, :session_id),
          project: Map.get(retry_entry, :project),
          branch_name: Map.get(retry_entry, :branch_name),
          issue_url: Map.get(retry_entry, :issue_url),
          retry_history: Map.get(retry_entry, :retry_history, [])
        }

        {:ok, attempt, metadata, persist_state(%{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)})}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case safe_fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set(issue)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(issue_or_identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(%Issue{} = issue, worker_host) do
    Workspace.remove_issue_workspaces(issue, worker_host)
  end

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    terminal_states = Config.project_configs() |> Enum.flat_map(& &1.terminal_states) |> Enum.uniq()

    case safe_fetch_terminal_issues(terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{} = issue ->
            cleanup_issue_workspace(issue)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp safe_fetch_terminal_issues(terminal_states) do
    Tracker.fetch_issues_by_states(terminal_states)
  rescue
    error ->
      {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp safe_fetch_candidate_issues do
    Tracker.fetch_candidate_issues()
  rescue
    error ->
      {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set(issue)) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], metadata)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
    |> persist_state()
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_project(previous_retry, metadata) do
    metadata[:project] || Map.get(previous_retry, :project)
  end

  defp pick_retry_session_id(previous_retry, metadata) do
    metadata[:session_id] || Map.get(previous_retry, :session_id)
  end

  defp pick_retry_branch_name(previous_retry, metadata) do
    metadata[:branch_name] || Map.get(previous_retry, :branch_name)
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp append_retry_history(history, event) when is_list(history) and is_map(event) do
    (history ++ [Map.put(event, :scheduled_at, DateTime.utc_now())])
    |> Enum.take(-@event_history_limit)
  end

  defp append_retry_history(_history, event) when is_map(event) do
    append_retry_history([], event)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if server_available?(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec control_action(String.t(), map()) :: {:ok, map()} | {:error, term()} | :unavailable
  def control_action(action, params \\ %{}) do
    control_action(__MODULE__, action, params)
  end

  @spec control_action(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, term()} | :unavailable
  def control_action(server, action, params) when is_binary(action) and is_map(params) do
    if server_available?(server) do
      GenServer.call(server, {:control_action, normalize_control_action(action), params})
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if server_available?(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          project: Map.get(metadata, :project) || metadata.issue.project,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          current_turn_id: Map.get(metadata, :current_turn_id),
          branch_name: metadata.issue.branch_name,
          issue_url: metadata.issue.url,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          retry_attempt: Map.get(metadata, :retry_attempt, 0),
          retry_history: Map.get(metadata, :retry_history, []),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          event_history: Map.get(metadata, :event_history, []),
          mcp_servers: mcp_servers_snapshot(Map.get(metadata, :mcp_servers, %{})),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          project: Map.get(retry, :project),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          session_id: Map.get(retry, :session_id),
          branch_name: Map.get(retry, :branch_name),
          issue_url: Map.get(retry, :issue_url),
          retry_history: Map.get(retry, :retry_history, [])
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    {payload, state} = queue_refresh(state)
    {:reply, payload, state}
  end

  def handle_call({:control_action, action, params}, _from, state) do
    {reply, state} = handle_control_action(action, params, state)

    if match?({:ok, _payload}, reply) do
      notify_dashboard()
    end

    {:reply, reply, state}
  end

  defp handle_control_action("dispatch-now", _params, %State{} = state) do
    {payload, state} = queue_refresh(state)
    {{:ok, Map.merge(payload, %{action: "dispatch-now", status: "queued"})}, state}
  end

  defp handle_control_action(action, _params, %State{} = state) when action in ["pause", "resume"] do
    {{:error, {:control_not_implemented, action}}, state}
  end

  defp handle_control_action(action, params, %State{} = state) when action in ["stop", "cancel"] do
    case control_issue_id(params, state) do
      {:ok, issue_id} ->
        stop_or_cancel_issue(action, issue_id, state)

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp handle_control_action("retry-now" = action, params, %State{} = state) do
    with {:ok, issue_id} <- control_issue_id(params, state),
         {:ok, retry} <- fetch_retry_attempt(state, issue_id),
         {:ok, issues} <- safe_fetch_candidate_issues() do
      state = clear_retry_attempt(state, issue_id)

      {_reply, state} =
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, retry.attempt, retry_metadata(retry))

      {{:ok, %{action: action, issue_id: issue_id, attempt: retry.attempt, status: "retry_requested"}}, state}
    else
      {:error, :retry_not_found} -> {{:error, :retry_not_found}, state}
      {:error, :issue_not_found} -> {{:error, :issue_not_found}, state}
      {:error, {:invalid_control_request, _message} = reason} -> {{:error, reason}, state}
      {:error, reason} -> {{:error, {:tracker_error, reason}}, state}
    end
  end

  defp handle_control_action("clear-retry" = action, params, %State{} = state) do
    with {:ok, issue_id} <- control_issue_id(params, state),
         {:ok, _retry} <- fetch_retry_attempt(state, issue_id) do
      state = clear_retry_attempt(state, issue_id)
      {{:ok, %{action: action, issue_id: issue_id, status: "retry_cleared"}}, state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp handle_control_action("release-claim" = action, params, %State{} = state) do
    case control_issue_id(params, state, require_known_identifier?: false) do
      {:ok, issue_id} ->
        release_claim(action, issue_id, state)

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp handle_control_action(action, _params, %State{} = state) do
    {{:error, {:unsupported_control_action, action}}, state}
  end

  defp stop_or_cancel_issue(action, issue_id, %State{} = state) do
    cond do
      Map.has_key?(state.running, issue_id) ->
        state = terminate_running_issue(state, issue_id, false)
        {{:ok, %{action: action, issue_id: issue_id, status: "stopped"}}, state}

      Map.has_key?(state.retry_attempts, issue_id) ->
        state = clear_retry_attempt(state, issue_id)
        {{:ok, %{action: action, issue_id: issue_id, status: "retry_cleared"}}, state}

      true ->
        {{:error, :issue_not_found}, state}
    end
  end

  defp release_claim(action, issue_id, %State{} = state) do
    cond do
      Map.has_key?(state.running, issue_id) or Map.has_key?(state.retry_attempts, issue_id) ->
        {{:error, :active_claim}, state}

      MapSet.member?(state.claimed, issue_id) ->
        state = persist_state(%{state | claimed: MapSet.delete(state.claimed, issue_id)})
        {{:ok, %{action: action, issue_id: issue_id, status: "claim_released"}}, state}

      true ->
        {{:error, :claim_not_found}, state}
    end
  end

  defp queue_refresh(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {%{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp fetch_retry_attempt(%State{} = state, issue_id) do
    case Map.fetch(state.retry_attempts, issue_id) do
      {:ok, retry} -> {:ok, retry}
      :error -> {:error, :retry_not_found}
    end
  end

  defp clear_retry_attempt(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)

      _ ->
        :ok
    end

    %{
      state
      | retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id)
    }
    |> persist_state()
  end

  defp retry_metadata(retry) when is_map(retry) do
    %{
      identifier: Map.get(retry, :identifier),
      error: Map.get(retry, :error),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      session_id: Map.get(retry, :session_id),
      project: Map.get(retry, :project)
    }
  end

  defp control_issue_id(params, state, opts \\ []) when is_map(params) do
    require_known_identifier? = Keyword.get(opts, :require_known_identifier?, true)

    cond do
      issue_id = string_param(params, "issue_id") ->
        {:ok, issue_id}

      issue_identifier = string_param(params, "issue_identifier") ->
        case issue_id_for_identifier(state, issue_identifier) do
          nil when require_known_identifier? -> {:error, :issue_not_found}
          nil -> {:error, {:invalid_control_request, "issue_id is required for unknown or stale claims"}}
          issue_id -> {:ok, issue_id}
        end

      true ->
        {:error, {:invalid_control_request, "issue_id or issue_identifier is required"}}
    end
  end

  defp string_param(params, key) do
    params
    |> Map.get(key)
    |> normalize_param_string()
  end

  defp normalize_param_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_param_string(_value), do: nil

  defp issue_id_for_identifier(%State{} = state, issue_identifier) do
    Enum.find_value(state.running, fn
      {issue_id, %{identifier: ^issue_identifier}} -> issue_id
      _entry -> nil
    end) ||
      Enum.find_value(state.retry_attempts, fn
        {issue_id, %{identifier: ^issue_identifier}} -> issue_id
        _entry -> nil
      end)
  end

  defp normalize_control_action(action) when is_binary(action) do
    action
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp server_available?(server) when is_atom(server), do: not is_nil(Process.whereis(server))
  defp server_available?(server) when is_pid(server), do: Process.alive?(server)
  defp server_available?(_server), do: false

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_update = summarize_codex_update(update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: codex_update,
        session_id: session_id_for_update(running_entry.session_id, update),
        current_turn_id: current_turn_id_for_update(Map.get(running_entry, :current_turn_id), update),
        last_codex_event: event,
        event_history: append_event_history(Map.get(running_entry, :event_history, []), codex_update, update),
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update),
        mcp_servers: mcp_servers_for_update(Map.get(running_entry, :mcp_servers, %{}), update)
      }),
      token_delta
    }
  end

  defp mcp_servers_snapshot(servers) when is_map(servers) do
    servers
    |> Map.values()
    |> Enum.sort_by(fn server ->
      server |> Map.get(:name, "") |> to_string() |> String.downcase()
    end)
  end

  defp mcp_servers_snapshot(_servers), do: []

  defp mcp_servers_for_update(existing, update) do
    existing = if is_map(existing), do: existing, else: %{}

    case mcp_server_status_update(update) do
      nil ->
        existing

      %{name: name} = server ->
        Map.put(existing, name, server)
    end
  end

  defp mcp_server_status_update(update) when is_map(update) do
    payload = Map.get(update, :payload) || Map.get(update, "payload")
    method = map_path(payload, ["method"]) || map_path(payload, [:method])

    with true <- method in ["codex/event/mcp_startup_update", "mcp_startup_update"],
         %{} = msg <- map_path(payload, ["params", "msg"]) || map_path(payload, [:params, :msg]),
         server when is_binary(server) <- msg |> map_key_value(["server", :server]) |> present_string() do
      status = mcp_status_state(msg) || "updated"
      detail = mcp_status_detail(msg)

      %{
        name: server,
        status: status,
        detail: detail,
        updated_at: Map.get(update, :timestamp) || Map.get(update, "timestamp")
      }
    else
      _ -> nil
    end
  end

  defp mcp_status_state(msg) when is_map(msg) do
    status = map_key_value(msg, ["status", :status])

    state =
      case status do
        %{} -> map_key_value(status, ["state", :state])
        value -> value
      end

    present_string(state)
  end

  defp mcp_status_detail(msg) when is_map(msg) do
    status = map_key_value(msg, ["status", :status])

    [
      map_key_value(msg, ["message", :message]),
      map_key_value(msg, ["error", :error]),
      map_key_value(msg, ["detail", :detail]),
      map_key_value(msg, ["details", :details]),
      map_key_value(msg, ["reason", :reason]),
      status_detail(status)
    ]
    |> Enum.find_value(&present_string/1)
  end

  defp status_detail(status) when is_map(status) do
    [
      map_key_value(status, ["message", :message]),
      map_key_value(status, ["error", :error]),
      map_key_value(status, ["detail", :detail]),
      map_key_value(status, ["details", :details]),
      map_key_value(status, ["reason", :reason])
    ]
    |> Enum.find_value(&present_string/1)
  end

  defp status_detail(_status), do: nil

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(nil), do: nil
  defp present_string(value) when is_atom(value), do: value |> Atom.to_string() |> present_string()
  defp present_string(value) when is_integer(value), do: Integer.to_string(value)
  defp present_string(value) when is_float(value), do: Float.to_string(value)
  defp present_string(value) when is_map(value) or is_list(value), do: inspect(value)
  defp present_string(_value), do: nil

  defp map_key_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_key_value(_map, _keys), do: nil

  defp map_path(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case current do
        %{} -> {:cont, Map.get(current, key)}
        _ -> {:halt, nil}
      end
    end)
  end

  defp map_path(_map, _keys), do: nil

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp append_event_history(history, codex_update, update) when is_list(history) do
    event = %{
      at: update[:timestamp],
      event: update[:event],
      category: codex_event_category(update),
      summary: StatusDashboard.humanize_codex_message(codex_update),
      turn_id: turn_id_from_update(update)
    }

    (history ++ [event])
    |> Enum.take(-@event_history_limit)
  end

  defp append_event_history(_history, codex_update, update), do: append_event_history([], codex_update, update)

  defp current_turn_id_for_update(existing_turn_id, update) do
    turn_id_from_update(update) || existing_turn_id
  end

  defp turn_id_from_update(update) when is_map(update) do
    payload = update[:payload] || update[:raw] || %{}

    map_value(payload, ["params", "turn", "id"]) ||
      map_value(payload, [:params, :turn, :id]) ||
      map_value(payload, ["params", "turn_id"]) ||
      map_value(payload, [:params, :turn_id]) ||
      map_value(payload, ["turn_id"]) ||
      map_value(payload, [:turn_id])
  end

  defp codex_event_category(update) do
    method = update_method(update)
    event = update[:event] |> to_string()

    cond do
      event == "session_started" -> "session"
      method_contains?(method, ["tokenUsage", "token_count"]) or String.contains?(event, "token_count") -> "tokens"
      method_contains?(method, ["exec_command", "mcp_tool", "tool_call", "tool"]) -> "tool"
      method_contains?(method, ["agent_message", "user_message", "reasoning", "message"]) -> "message"
      method_contains?(method, ["turn/"]) -> "turn"
      true -> "event"
    end
  end

  defp update_method(update) when is_map(update) do
    payload = update[:payload] || update[:raw] || %{}
    map_value(payload, ["method"]) || map_value(payload, [:method])
  end

  defp method_contains?(method, needles) when is_binary(method) and is_list(needles) do
    Enum.any?(needles, &String.contains?(method, &1))
  end

  defp method_contains?(_method, _needles), do: false

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp restore_persisted_state(%State{} = state) do
    path = Config.orchestrator_state_path()

    case Persistence.load(path) do
      {:ok, decoded} ->
        state
        |> restore_retry_entries(decoded)
        |> restore_running_entries(decoded)
        |> restore_codex_totals(decoded["codex_totals"])
        |> restore_codex_rate_limits(decoded["codex_rate_limits"])

      {:error, :enoent} ->
        state

      {:error, reason} ->
        Logger.warning("Skipping orchestrator state restore path=#{path} reason=#{inspect(reason)}")
        state
    end
  end

  defp persist_state(%State{} = state) do
    path = Config.orchestrator_state_path()

    payload = %{
      "version" => @persistence_version,
      "saved_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "running" => encode_running_entries(state.running),
      "retry_attempts" => encode_retry_entries(state.retry_attempts),
      "running_sessions" => encode_running_session_list(state.running),
      "retry_attempt_list" => encode_retry_entry_list(state.retry_attempts),
      "codex_totals" => encode_map(state.codex_totals),
      "codex_rate_limits" => encode_map(state.codex_rate_limits)
    }

    case Persistence.save(path, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist orchestrator state path=#{path} reason=#{inspect(reason)}")
    end

    state
  end

  defp restore_running_entries(%State{} = state, payload) when is_map(payload) do
    restore_running_entries(state, payload["running"], payload["running_sessions"])
  end

  defp restore_running_entries(%State{} = state, running, running_sessions) do
    restored_running =
      %{}
      |> restore_running_map(running)
      |> restore_running_list(running_sessions)

    %{
      state
      | running: restored_running,
        claimed: MapSet.new(Map.keys(restored_running) ++ Map.keys(state.retry_attempts))
    }
  end

  defp restore_running_map(acc, running) when is_map(running) do
    Enum.reduce(running, acc, fn {issue_id, entry}, running_acc ->
      case decode_running_entry(issue_id, entry) do
        nil -> running_acc
        decoded -> Map.put(running_acc, issue_id, decoded)
      end
    end)
  end

  defp restore_running_map(acc, _running), do: acc

  defp restore_running_list(acc, running_sessions) when is_list(running_sessions) do
    Enum.reduce(running_sessions, acc, fn entry, running_acc ->
      issue_id = string_value(entry["issue_id"])

      case decode_running_entry(issue_id, entry) do
        nil -> running_acc
        decoded -> Map.put(running_acc, issue_id, decoded)
      end
    end)
  end

  defp restore_running_list(acc, _running_sessions), do: acc

  defp restore_retry_entries(%State{} = state, payload) when is_map(payload) do
    restore_retry_entries(state, payload["retry_attempts"], payload["retry_attempt_list"])
  end

  defp restore_retry_entries(%State{} = state, retry_attempts, retry_attempt_list) do
    now_wall_ms = System.system_time(:millisecond)
    now_ms = System.monotonic_time(:millisecond)

    restored_retries =
      %{}
      |> restore_retry_map(retry_attempts, now_wall_ms, now_ms)
      |> restore_retry_list(retry_attempts, now_wall_ms, now_ms)
      |> restore_retry_list(retry_attempt_list, now_wall_ms, now_ms)

    %{state | retry_attempts: restored_retries, claimed: MapSet.new(Map.keys(state.running) ++ Map.keys(restored_retries))}
  end

  defp restore_retry_map(acc, retry_attempts, now_wall_ms, now_ms) when is_map(retry_attempts) do
    Enum.reduce(retry_attempts, acc, fn {issue_id, entry}, retry_acc ->
      case decode_retry_entry(issue_id, entry, now_wall_ms, now_ms) do
        nil -> retry_acc
        retry -> Map.put(retry_acc, issue_id, retry)
      end
    end)
  end

  defp restore_retry_map(acc, _retry_attempts, _now_wall_ms, _now_ms), do: acc

  defp restore_retry_list(acc, retry_attempts, now_wall_ms, now_ms) when is_list(retry_attempts) do
    Enum.reduce(retry_attempts, acc, fn entry, retry_acc ->
      issue_id = string_value(entry["issue_id"])

      entry =
        if is_nil(entry["due_at_wall_ms"]) and not is_nil(entry["due_at_unix_ms"]) do
          Map.put(entry, "due_at_wall_ms", entry["due_at_unix_ms"])
        else
          entry
        end

      case decode_retry_entry(issue_id, entry, now_wall_ms, now_ms) do
        nil -> retry_acc
        retry -> Map.put(retry_acc, issue_id, retry)
      end
    end)
  end

  defp restore_retry_list(acc, _retry_attempts, _now_wall_ms, _now_ms), do: acc

  defp restore_codex_totals(%State{} = state, totals) when is_map(totals) do
    %{
      state
      | codex_totals: %{
          input_tokens: integer_value(totals["input_tokens"], 0),
          output_tokens: integer_value(totals["output_tokens"], 0),
          total_tokens: integer_value(totals["total_tokens"], 0),
          seconds_running: integer_value(totals["seconds_running"], 0)
        }
    }
  end

  defp restore_codex_totals(state, _totals), do: state

  defp restore_codex_rate_limits(%State{} = state, rate_limits) when is_map(rate_limits) do
    %{state | codex_rate_limits: rate_limits}
  end

  defp restore_codex_rate_limits(state, _rate_limits), do: state

  defp decode_running_entry(issue_id, entry) when is_binary(issue_id) and is_map(entry) do
    issue = decode_issue(entry["issue"], issue_id, entry["identifier"], entry["project"])

    %{
      pid: nil,
      ref: nil,
      identifier: issue.identifier,
      issue: issue,
      project: issue.project,
      worker_host: entry["worker_host"],
      workspace_path: entry["workspace_path"],
      session_id: entry["session_id"],
      current_turn_id: entry["current_turn_id"],
      last_codex_message: entry["last_codex_message"],
      last_codex_timestamp: decode_datetime(entry["last_codex_timestamp"]),
      last_codex_event: entry["last_codex_event"],
      event_history: decode_event_history(entry["event_history"]),
      codex_app_server_pid: entry["codex_app_server_pid"],
      codex_input_tokens: integer_value(entry["codex_input_tokens"], 0),
      codex_output_tokens: integer_value(entry["codex_output_tokens"], 0),
      codex_total_tokens: integer_value(entry["codex_total_tokens"], 0),
      codex_last_reported_input_tokens: integer_value(entry["codex_last_reported_input_tokens"], 0),
      codex_last_reported_output_tokens: integer_value(entry["codex_last_reported_output_tokens"], 0),
      codex_last_reported_total_tokens: integer_value(entry["codex_last_reported_total_tokens"], 0),
      turn_count: integer_value(entry["turn_count"], 0),
      retry_attempt: integer_value(entry["retry_attempt"], 0),
      retry_history: decode_retry_history(entry["retry_history"]),
      restored: entry["restored"] != false,
      started_at: decode_datetime(entry["started_at"]) || DateTime.utc_now()
    }
  end

  defp decode_running_entry(_issue_id, _entry), do: nil

  defp decode_retry_entry(issue_id, entry, now_wall_ms, now_ms) when is_binary(issue_id) and is_map(entry) do
    attempt = integer_value(entry["attempt"], 1)
    due_at_wall_ms = integer_value(entry["due_at_wall_ms"], now_wall_ms)
    delay_ms = max(0, due_at_wall_ms - now_wall_ms)
    retry_token = make_ref()

    %{
      attempt: attempt,
      timer_ref: Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms),
      retry_token: retry_token,
      due_at_ms: now_ms + delay_ms,
      due_at_wall_ms: due_at_wall_ms,
      identifier: entry["identifier"] || issue_id,
      error: entry["error"],
      worker_host: entry["worker_host"],
      workspace_path: entry["workspace_path"],
      session_id: entry["session_id"],
      project: entry["project"],
      branch_name: entry["branch_name"],
      issue_url: entry["issue_url"],
      retry_history: decode_retry_history(entry["retry_history"])
    }
  end

  defp decode_retry_entry(_issue_id, _entry, _now_wall_ms, _now_ms), do: nil

  defp decode_issue(issue, issue_id, identifier, project) when is_map(issue) do
    decoded_identifier = issue["identifier"] || identifier || issue_id

    %Issue{
      id: issue["id"] || issue_id,
      identifier: decoded_identifier,
      title: issue_title(issue, decoded_identifier),
      description: issue["description"],
      priority: issue["priority"],
      state: issue["state"],
      branch_name: issue["branch_name"],
      url: issue["url"],
      assignee_id: issue["assignee_id"],
      project: issue["project"] || project,
      blocked_by: issue["blocked_by"] || [],
      labels: issue["labels"] || [],
      assigned_to_worker: issue["assigned_to_worker"] != false,
      created_at: decode_datetime(issue["created_at"]),
      updated_at: decode_datetime(issue["updated_at"])
    }
  end

  defp decode_issue(_issue, issue_id, identifier, project) do
    %Issue{
      id: issue_id,
      identifier: identifier || issue_id,
      title: identifier || issue_id,
      state: "In Progress",
      project: project
    }
  end

  defp issue_title(issue, fallback_identifier) do
    issue["title"] || fallback_identifier
  end

  defp encode_running_entries(running) when is_map(running) do
    Map.new(running, fn {issue_id, entry} ->
      {issue_id,
       %{
         "identifier" => Map.get(entry, :identifier),
         "issue" => encode_issue(Map.get(entry, :issue)),
         "project" => Map.get(entry, :project),
         "worker_host" => Map.get(entry, :worker_host),
         "workspace_path" => Map.get(entry, :workspace_path),
         "session_id" => Map.get(entry, :session_id),
         "current_turn_id" => Map.get(entry, :current_turn_id),
         "last_codex_message" => encode_optional_term(Map.get(entry, :last_codex_message)),
         "last_codex_timestamp" => encode_datetime(Map.get(entry, :last_codex_timestamp)),
         "last_codex_event" => encode_optional_term(Map.get(entry, :last_codex_event)),
         "event_history" => encode_event_history(Map.get(entry, :event_history)),
         "codex_app_server_pid" => Map.get(entry, :codex_app_server_pid),
         "codex_input_tokens" => Map.get(entry, :codex_input_tokens, 0),
         "codex_output_tokens" => Map.get(entry, :codex_output_tokens, 0),
         "codex_total_tokens" => Map.get(entry, :codex_total_tokens, 0),
         "codex_last_reported_input_tokens" => Map.get(entry, :codex_last_reported_input_tokens, 0),
         "codex_last_reported_output_tokens" => Map.get(entry, :codex_last_reported_output_tokens, 0),
         "codex_last_reported_total_tokens" => Map.get(entry, :codex_last_reported_total_tokens, 0),
         "turn_count" => Map.get(entry, :turn_count, 0),
         "retry_attempt" => Map.get(entry, :retry_attempt, 0),
         "retry_history" => encode_retry_history(Map.get(entry, :retry_history)),
         "started_at" => encode_datetime(Map.get(entry, :started_at))
       }}
    end)
  end

  defp encode_retry_entries(retry_attempts) when is_map(retry_attempts) do
    Map.new(retry_attempts, fn {issue_id, entry} ->
      {issue_id,
       %{
         "attempt" => Map.get(entry, :attempt),
         "due_at_wall_ms" => Map.get(entry, :due_at_wall_ms),
         "identifier" => Map.get(entry, :identifier),
         "error" => Map.get(entry, :error),
         "worker_host" => Map.get(entry, :worker_host),
         "workspace_path" => Map.get(entry, :workspace_path),
         "session_id" => Map.get(entry, :session_id),
         "project" => Map.get(entry, :project),
         "branch_name" => Map.get(entry, :branch_name),
         "issue_url" => Map.get(entry, :issue_url),
         "retry_history" => encode_retry_history(Map.get(entry, :retry_history))
       }}
    end)
  end

  defp encode_running_session_list(running) when is_map(running) do
    running
    |> encode_running_entries()
    |> Enum.map(fn {issue_id, entry} -> Map.put(entry, "issue_id", issue_id) end)
  end

  defp encode_retry_entry_list(retry_attempts) when is_map(retry_attempts) do
    now_ms = System.monotonic_time(:millisecond)
    now_unix_ms = System.system_time(:millisecond)

    Enum.map(retry_attempts, fn {issue_id, entry} ->
      due_at_ms = Map.get(entry, :due_at_ms)
      due_in_ms = if is_integer(due_at_ms), do: max(0, due_at_ms - now_ms), else: 0

      %{
        "issue_id" => issue_id,
        "attempt" => Map.get(entry, :attempt),
        "due_at_unix_ms" => now_unix_ms + due_in_ms,
        "identifier" => Map.get(entry, :identifier),
        "error" => Map.get(entry, :error),
        "worker_host" => Map.get(entry, :worker_host),
        "workspace_path" => Map.get(entry, :workspace_path),
        "session_id" => Map.get(entry, :session_id),
        "project" => Map.get(entry, :project),
        "branch_name" => Map.get(entry, :branch_name),
        "issue_url" => Map.get(entry, :issue_url),
        "retry_history" => encode_retry_history(Map.get(entry, :retry_history))
      }
    end)
  end

  defp encode_issue(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "priority" => issue.priority,
      "state" => issue.state,
      "branch_name" => issue.branch_name,
      "url" => issue.url,
      "assignee_id" => issue.assignee_id,
      "project" => issue.project,
      "blocked_by" => issue.blocked_by,
      "labels" => issue.labels,
      "assigned_to_worker" => issue.assigned_to_worker,
      "created_at" => encode_datetime(issue.created_at),
      "updated_at" => encode_datetime(issue.updated_at)
    }
  end

  defp encode_issue(_issue), do: nil

  defp encode_map(value) when is_map(value), do: value
  defp encode_map(_value), do: nil

  defp encode_event_history(history) when is_list(history) do
    Enum.map(history, fn event ->
      %{
        "at" => encode_datetime(event[:at] || event["at"]),
        "event" => encode_optional_term(event[:event] || event["event"]),
        "category" => event[:category] || event["category"],
        "summary" => event[:summary] || event["summary"],
        "turn_id" => event[:turn_id] || event["turn_id"]
      }
    end)
  end

  defp encode_event_history(_history), do: []

  defp decode_event_history(history) when is_list(history) do
    history
    |> Enum.map(fn
      event when is_map(event) ->
        %{
          at: decode_datetime(event["at"]),
          event: event["event"],
          category: event["category"],
          summary: event["summary"],
          turn_id: event["turn_id"]
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_event_history(_history), do: []

  defp encode_retry_history(history) when is_list(history) do
    Enum.map(history, fn event ->
      %{
        "attempt" => event[:attempt] || event["attempt"],
        "scheduled_at" => encode_datetime(event[:scheduled_at] || event["scheduled_at"]),
        "due_at_wall_ms" => event[:due_at_wall_ms] || event["due_at_wall_ms"],
        "delay_ms" => event[:delay_ms] || event["delay_ms"],
        "delay_type" => encode_optional_term(event[:delay_type] || event["delay_type"]),
        "error" => event[:error] || event["error"]
      }
    end)
  end

  defp encode_retry_history(_history), do: []

  defp decode_retry_history(history) when is_list(history) do
    history
    |> Enum.map(fn
      event when is_map(event) ->
        %{
          attempt: integer_value(event["attempt"], 0),
          scheduled_at: decode_datetime(event["scheduled_at"]),
          due_at_wall_ms: integer_value(event["due_at_wall_ms"], nil),
          delay_ms: integer_value(event["delay_ms"], 0),
          delay_type: event["delay_type"],
          error: event["error"]
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_retry_history(_history), do: []

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_datetime), do: nil

  defp encode_optional_term(nil), do: nil
  defp encode_optional_term(value) when is_binary(value), do: value
  defp encode_optional_term(value), do: inspect(value)

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp decode_datetime(_value), do: nil

  defp string_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp string_value(_value), do: nil

  defp map_value(map, [key]) when is_map(map), do: Map.get(map, key)

  defp map_value(map, [key | rest]) when is_map(map) and is_list(rest) do
    case Map.get(map, key) do
      %{} = nested -> map_value(nested, rest)
      _ -> nil
    end
  end

  defp map_value(_map, _path), do: nil

  defp integer_value(value, _default) when is_integer(value), do: value

  defp integer_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp integer_value(_value, default), do: default

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    terminal_states = terminal_state_set(issue, terminal_states)

    candidate_issue?(issue, active_state_set(issue), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
