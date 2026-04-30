defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, LogFile, Orchestrator, ProjectConfig, StatusDashboard, Tracker}

  @log_empty_state "No local log files found for this run."
  @evidence_empty_state "No validation evidence files found for this run."
  @evidence_globs [
    ".codex/evidence/*",
    "evidence/*",
    ".github/media/*",
    "*.evidence.md",
    "LIVE_E2E_RESULT.txt"
  ]
  @link_limit 10

  @task_board_default_limit 50
  @task_board_max_limit 100

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        projects = Config.project_configs()
        running = Enum.map(snapshot.running, &running_entry_payload/1)
        retrying = Enum.map(snapshot.retrying, &retry_entry_payload/1)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          projects: project_command_centers(projects, snapshot, running, retrying),
          mcp_servers: mcp_server_payloads(snapshot.running),
          polling: Map.put_new(snapshot.polling, :paused?, false),
          controls: Map.get(snapshot, :controls, default_controls()),
          last_poll_result: Map.get(snapshot, :last_poll_result),
          running: running,
          retrying: retrying,
          claimed: Enum.map(Map.get(snapshot, :claimed, []), &claimed_entry_payload/1),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, snapshot)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, encode_datetimes(payload)}
    end
  end

  @spec control_payload(GenServer.name(), String.t()) ::
          {:ok, map()} | {:error, :unavailable}
  def control_payload(orchestrator, action), do: control_payload(orchestrator, action, nil)

  @spec project_refresh_payload(String.t(), GenServer.name()) ::
          {:ok, map()} | {:error, :project_not_found | :unavailable}
  def project_refresh_payload(project_id, orchestrator) when is_binary(project_id) do
    case find_project(project_id, Config.project_configs()) do
      nil ->
        {:error, :project_not_found}

      %ProjectConfig{} = project ->
        case refresh_payload(orchestrator) do
          {:ok, payload} ->
            {:ok,
             Map.put(payload, :project, %{
               id: project.id,
               name: project.name,
               tracker_project_slug: project.tracker_project_slug
             })}

          {:error, :unavailable} ->
            {:error, :unavailable}
        end
    end
  end

  @spec control_payload(GenServer.name(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :unavailable}
  @spec control_payload(String.t(), map(), GenServer.name()) ::
          {:ok, pos_integer(), map()} | {:error, pos_integer(), map()}
  def control_payload(orchestrator, "pause_global", _target) do
    orchestrator
    |> Orchestrator.pause_polling(:global)
    |> control_result()
  end

  def control_payload(orchestrator, "resume_global", _target) do
    orchestrator
    |> Orchestrator.resume_polling(:global)
    |> control_result()
  end

  def control_payload(orchestrator, "pause_project", project_id) when is_binary(project_id) do
    orchestrator
    |> Orchestrator.pause_polling({:project, project_id})
    |> control_result()
  end

  def control_payload(orchestrator, "resume_project", project_id) when is_binary(project_id) do
    orchestrator
    |> Orchestrator.resume_polling({:project, project_id})
    |> control_result()
  end

  def control_payload(orchestrator, "dispatch_project_now", project_id) when is_binary(project_id) do
    orchestrator
    |> Orchestrator.request_project_dispatch(project_id)
    |> control_result()
  end

  def control_payload(orchestrator, "cancel_run", issue_identifier) when is_binary(issue_identifier) do
    orchestrator
    |> Orchestrator.cancel_run(issue_identifier)
    |> control_result()
  end

  def control_payload(orchestrator, "retry_now", issue_identifier) when is_binary(issue_identifier) do
    orchestrator
    |> Orchestrator.retry_now(issue_identifier)
    |> control_result()
  end

  def control_payload(orchestrator, "clear_retry", issue_identifier) when is_binary(issue_identifier) do
    orchestrator
    |> Orchestrator.clear_retry(issue_identifier)
    |> control_result()
  end

  def control_payload(orchestrator, "release_claim", issue_identifier) when is_binary(issue_identifier) do
    orchestrator
    |> Orchestrator.release_claim(issue_identifier)
    |> control_result()
  end

  def control_payload(action, params, orchestrator) when is_binary(action) and is_map(params) do
    normalized_action = normalize_control_action(action)

    case Orchestrator.control_action(orchestrator, normalized_action, params) do
      {:ok, result} ->
        {:ok, 202,
         %{
           ok: true,
           action: normalized_action,
           result: json_value(result)
         }}

      {:error, reason} ->
        {status, code, message, details} = control_error(reason)
        {:error, status, control_error_payload(normalized_action, code, message, details)}

      :unavailable ->
        {:error, 503,
         control_error_payload(
           normalized_action,
           "orchestrator_unavailable",
           "Orchestrator is unavailable",
           nil
         )}
    end
  end

  def control_payload(_orchestrator, action, target) when is_binary(action) do
    {:ok,
     %{
       ok: false,
       action: action,
       status: "rejected",
       code: "unsupported_action",
       message: "Unsupported orchestrator control",
       target: %{id: target},
       requested_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  @spec task_board_payload(GenServer.name(), timeout(), map()) ::
          {:ok, map()} | {:error, {:invalid_request, String.t()}} | {:error, {:tracker_error, term()}}
  def task_board_payload(orchestrator, snapshot_timeout_ms, params \\ %{}) when is_map(params) do
    with {:ok, filters} <- task_board_filters(params),
         {:ok, issues} <- Tracker.fetch_issues_by_states(filters.states) do
      snapshot = Orchestrator.snapshot(orchestrator, snapshot_timeout_ms)
      {:ok, task_board_payload_body(issues, snapshot, filters)}
    else
      {:error, {:invalid_request, _message}} = error -> error
      {:error, reason} -> {:error, {:tracker_error, reason}}
    end
  end

  defp task_board_payload_body(issues, snapshot, filters) do
    filtered_issues = Enum.filter(issues, &task_matches_filters?(&1, filters))
    total = length(filtered_issues)
    page_issues = Enum.slice(filtered_issues, filters.after, filters.limit)
    overlay = runtime_overlay(snapshot)

    %{
      generated_at: generated_at(),
      filters: %{
        project_id: filters.project_id,
        project_slug: filters.project_slug,
        states: filters.states,
        limit: filters.limit,
        after: filters.after
      },
      pagination: %{
        limit: filters.limit,
        after: filters.after,
        next_after: next_after(filters.after, filters.limit, total),
        total: total
      },
      projects: Enum.map(Config.project_configs(), &ProjectConfig.summary/1),
      runtime: %{status: overlay.status},
      tasks: Enum.map(page_issues, &task_payload(&1, overlay))
    }
  end

  defp task_payload(issue, overlay) do
    running = Map.get(overlay.running_by_id, issue.id)
    retry = Map.get(overlay.retrying_by_id, issue.id)
    configured_project = Config.project_config_for_issue(issue)

    %{
      issue: tracker_issue_payload(issue),
      project: project_payload(Map.get(issue, :project)),
      configured_project: ProjectConfig.summary(configured_project),
      runtime: %{
        status: task_runtime_status(running, retry, overlay.status),
        running: running && running_entry_payload(running),
        retry: retry && retry_entry_payload(retry)
      }
    }
  end

  defp tracker_issue_payload(issue) do
    %{
      id: Map.get(issue, :id),
      identifier: Map.get(issue, :identifier),
      title: Map.get(issue, :title),
      description: Map.get(issue, :description),
      priority: Map.get(issue, :priority),
      state: Map.get(issue, :state),
      branch_name: Map.get(issue, :branch_name),
      url: Map.get(issue, :url),
      assignee_id: Map.get(issue, :assignee_id),
      labels: Map.get(issue, :labels, []),
      blocked_by: Enum.map(Map.get(issue, :blocked_by, []), &blocked_by_payload/1),
      assigned_to_worker: Map.get(issue, :assigned_to_worker, true),
      created_at: iso8601(Map.get(issue, :created_at)),
      updated_at: iso8601(Map.get(issue, :updated_at))
    }
  end

  defp blocked_by_payload(blocker) when is_map(blocker) do
    %{
      id: blocker[:id] || blocker["id"],
      identifier: blocker[:identifier] || blocker["identifier"],
      state: blocker[:state] || blocker["state"]
    }
  end

  defp blocked_by_payload(_blocker), do: %{id: nil, identifier: nil, state: nil}

  defp runtime_overlay(%{} = snapshot) do
    %{
      status: "available",
      running_by_id: Map.new(Map.get(snapshot, :running, []), &{&1.issue_id, &1}),
      retrying_by_id: Map.new(Map.get(snapshot, :retrying, []), &{&1.issue_id, &1})
    }
  end

  defp runtime_overlay(:timeout), do: unavailable_runtime_overlay("snapshot_timeout")
  defp runtime_overlay(:unavailable), do: unavailable_runtime_overlay("snapshot_unavailable")

  defp unavailable_runtime_overlay(status) do
    %{status: status, running_by_id: %{}, retrying_by_id: %{}}
  end

  defp task_runtime_status(running, retry, _overlay_status) when not is_nil(running) and not is_nil(retry),
    do: "running"

  defp task_runtime_status(running, _retry, _overlay_status) when not is_nil(running), do: "running"
  defp task_runtime_status(_running, retry, _overlay_status) when not is_nil(retry), do: "retrying"
  defp task_runtime_status(_running, _retry, "available"), do: "idle"
  defp task_runtime_status(_running, _retry, overlay_status), do: overlay_status

  defp task_matches_filters?(issue, filters) do
    configured_project = Config.project_config_for_issue(issue)
    project = Map.get(issue, :project)

    matches_project_id?(configured_project, project, filters.project_id) and
      matches_project_slug?(configured_project, project, filters.project_slug)
  end

  defp matches_project_id?(_configured_project, _project, nil), do: true

  defp matches_project_id?(configured_project, project, project_id) do
    project_id in [
      configured_project.id,
      project_value(project, :id),
      project_value(project, :name)
    ]
  end

  defp matches_project_slug?(_configured_project, _project, nil), do: true

  defp matches_project_slug?(configured_project, project, project_slug) do
    project_slug in [
      configured_project.tracker_project_slug,
      project_value(project, :slug),
      project_value(project, :slug_id)
    ]
  end

  defp project_value(project, key) when is_map(project), do: project[key] || project[to_string(key)]
  defp project_value(_project, _key), do: nil

  defp next_after(offset, limit, total) do
    next_offset = offset + limit
    if next_offset < total, do: next_offset, else: nil
  end

  defp task_board_filters(params) do
    with {:ok, limit} <- positive_integer_param(params["limit"], @task_board_default_limit, @task_board_max_limit, "limit"),
         {:ok, after_offset} <- non_negative_integer_param(params["after"], 0, "after") do
      states = requested_states(params) || default_task_board_states()

      {:ok,
       %{
         states: states,
         project_id: string_param(params, "project_id") || string_param(params, "project"),
         project_slug: string_param(params, "project_slug"),
         limit: limit,
         after: after_offset
       }}
    end
  end

  defp requested_states(params) do
    [params["state"], params["states"]]
    |> Enum.flat_map(&list_param/1)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      states -> Enum.uniq(states)
    end
  end

  defp default_task_board_states do
    Config.project_configs()
    |> Enum.flat_map(& &1.active_states)
    |> Enum.uniq()
  end

  defp list_param(values) when is_list(values), do: Enum.flat_map(values, &list_param/1)
  defp list_param(value) when is_binary(value), do: [value]
  defp list_param(_value), do: []

  defp positive_integer_param(nil, default, _max, _name), do: {:ok, default}

  defp positive_integer_param(value, _default, max, name) do
    case parse_integer(value) do
      integer when is_integer(integer) and integer > 0 -> {:ok, min(integer, max)}
      _ -> {:error, {:invalid_request, "#{name} must be a positive integer"}}
    end
  end

  defp non_negative_integer_param(nil, default, _name), do: {:ok, default}

  defp non_negative_integer_param(value, _default, name) do
    case parse_integer(value) do
      integer when is_integer(integer) and integer >= 0 -> {:ok, integer}
      _ -> {:error, {:invalid_request, "#{name} must be a non-negative integer"}}
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp string_param(params, key) do
    params
    |> Map.get(key)
    |> normalize_string()
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp generated_at do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp normalize_control_action(action) do
    action
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp control_error({:invalid_control_request, message}),
    do: {400, "invalid_control_request", message, nil}

  defp control_error({:unsupported_control_action, action}),
    do: {400, "unsupported_control_action", "Unsupported control action", %{action: action}}

  defp control_error({:control_not_implemented, action}),
    do: {501, "control_not_implemented", "Control action is not implemented", %{action: action}}

  defp control_error({:tracker_error, reason}),
    do: {502, "tracker_error", "Tracker request failed", %{reason: inspect(reason)}}

  defp control_error(:issue_not_found), do: {404, "issue_not_found", "Issue not found", nil}
  defp control_error(:retry_not_found), do: {404, "retry_not_found", "Retry entry not found", nil}
  defp control_error(:claim_not_found), do: {404, "claim_not_found", "Claim not found", nil}
  defp control_error(:active_claim), do: {409, "active_claim", "Claim is attached to active runtime state", nil}

  defp control_error(reason),
    do: {500, "control_failed", "Control action failed", %{reason: inspect(reason)}}

  defp control_error_payload(action, code, message, nil) do
    %{ok: false, action: action, error: %{code: code, message: message}}
  end

  defp control_error_payload(action, code, message, details) do
    %{ok: false, action: action, error: %{code: code, message: message, details: json_value(details)}}
  end

  defp json_value(%DateTime{} = datetime), do: iso8601(datetime)

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {key, json_value(nested_value)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value), do: value

  defp issue_payload_body(issue_identifier, running, retry, snapshot) do
    workspace = workspace_payload(issue_identifier, running, retry)
    timeline = timeline_payload(running, retry)
    retry_history = retry_history_payload(running, retry)
    source_control = source_control_payload(running, retry)

    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: workspace,
      project: project_from_entries(running, retry),
      attempts: %{
        restart_count: restart_count(running, retry),
        current_retry_attempt: retry_attempt(running, retry)
      },
      current_turn: current_turn_payload(running, retry),
      runtime: runtime_payload(running, retry),
      tokens: tokens_payload(running),
      rate_limits: Map.get(snapshot, :rate_limits),
      source_control: source_control,
      retry_history: retry_history,
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: log_links_payload(workspace.path, workspace.host),
      evidence: evidence_links_payload(workspace.path, workspace.host),
      timeline: timeline,
      recent_events: Enum.take(timeline, -10),
      last_error: retry && sanitize_text(retry.error),
      tracked: %{
        branch_name: source_control.branch_name,
        issue_url: source_control.issue_url,
        pr_url: source_control.pr_url
      }
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(running, retry), do: max(retry_attempt(running, retry) - 1, 0)

  defp retry_attempt(running, retry) do
    cond do
      retry && is_integer(retry.attempt) -> retry.attempt
      running && is_integer(Map.get(running, :retry_attempt)) -> running.retry_attempt
      true -> 0
    end
  end

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      detail_path: "/runs/#{entry.identifier}",
      state: entry.state,
      project: project_payload(Map.get(entry, :project)),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      branch_name: Map.get(entry, :branch_name),
      issue_url: Map.get(entry, :issue_url),
      session_id: entry.session_id,
      current_turn_id: Map.get(entry, :current_turn_id),
      turn_count: Map.get(entry, :turn_count, 0),
      runtime_seconds: Map.get(entry, :runtime_seconds),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      mcp_servers: mcp_servers_for_entry(entry),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      detail_path: "/runs/#{entry.identifier}",
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: sanitize_text(entry.error),
      project: project_payload(Map.get(entry, :project)),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      branch_name: Map.get(entry, :branch_name),
      issue_url: Map.get(entry, :issue_url),
      session_id: Map.get(entry, :session_id)
    }
  end

  defp claimed_entry_payload(%{issue_id: issue_id} = entry) do
    %{
      issue_id: issue_id,
      safe?: Map.get(entry, :safe?, false)
    }
  end

  defp claimed_entry_payload(entry), do: entry

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      project: project_payload(Map.get(running, :project)),
      branch_name: Map.get(running, :branch_name),
      issue_url: Map.get(running, :issue_url),
      session_id: running.session_id,
      current_turn_id: Map.get(running, :current_turn_id),
      turn_count: Map.get(running, :turn_count, 0),
      retry_attempt: Map.get(running, :retry_attempt, 0),
      runtime_seconds: Map.get(running, :runtime_seconds),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      mcp_servers: mcp_servers_for_entry(running),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: sanitize_text(retry.error),
      project: project_payload(Map.get(retry, :project)),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      branch_name: Map.get(retry, :branch_name),
      issue_url: Map.get(retry, :issue_url),
      session_id: Map.get(retry, :session_id)
    }
  end

  defp workspace_payload(issue_identifier, running, retry) do
    %{
      path: workspace_path(issue_identifier, running, retry),
      host: workspace_host(running, retry)
    }
  end

  defp project_command_centers(projects, snapshot, running, retrying) do
    Enum.map(projects, fn project ->
      project_running = entries_for_project(running, project, projects)
      project_retrying = entries_for_project(retrying, project, projects)
      recent_failures = recent_failures(project_retrying)

      project
      |> ProjectConfig.summary()
      |> Map.merge(%{
        health: project_health(project, recent_failures),
        polling: project_polling_payload(snapshot),
        queue_counts: %{
          active_runs: length(project_running),
          retrying: length(project_retrying),
          total: length(project_running) + length(project_retrying)
        },
        active_runs: project_running,
        retry_pressure: retry_pressure(project_retrying),
        recent_failures: recent_failures
      })
    end)
  end

  defp project_health(%ProjectConfig{} = project, recent_failures) do
    base_health = ProjectConfig.health_summary(project)
    runtime_problems = runtime_failure_health_problems(recent_failures)
    problems = base_health.problems ++ runtime_problems

    %{
      status: if(problems == [], do: "healthy", else: "error"),
      problems: problems
    }
  end

  defp runtime_failure_health_problems(recent_failures) do
    recent_failures
    |> Enum.map(&runtime_failure_problem/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.code)
  end

  defp runtime_failure_problem(%{error: error}) when is_binary(error) do
    normalized = String.downcase(error)

    cond do
      String.contains?(normalized, "repository") ->
        %{code: "repository_setup_failed", severity: "error", message: "Recent repository setup failure: #{error}"}

      String.contains?(normalized, "workspace") ->
        %{code: "invalid_workspace_path", severity: "error", message: "Recent workspace failure: #{error}"}

      true ->
        nil
    end
  end

  defp runtime_failure_problem(_failure), do: nil

  defp project_polling_payload(snapshot) do
    %{
      status: polling_status(snapshot.polling),
      checking?: Map.get(snapshot.polling, :checking?) == true,
      next_poll_in_ms: Map.get(snapshot.polling, :next_poll_in_ms),
      poll_interval_ms: Map.get(snapshot.polling, :poll_interval_ms),
      last_result: Map.get(snapshot, :last_poll_result)
    }
  end

  defp polling_status(%{checking?: true}), do: "checking"
  defp polling_status(%{next_poll_in_ms: next_poll_in_ms}) when is_integer(next_poll_in_ms), do: "idle"
  defp polling_status(_polling), do: "unknown"

  defp entries_for_project(entries, %ProjectConfig{} = project, projects) do
    Enum.filter(entries, &entry_for_project?(&1, project, projects))
  end

  defp entry_for_project?(%{project: nil}, _project, projects), do: length(projects) == 1

  defp entry_for_project?(%{project: entry_project}, %ProjectConfig{} = project, _projects) do
    entry_keys = entry_project_keys(entry_project)
    project_keys = project_match_keys(project)
    Enum.any?(entry_keys, &(&1 in project_keys))
  end

  defp entry_for_project?(_entry, _project, _projects), do: false

  defp entry_project_keys(project) when is_map(project) do
    [
      project[:id],
      project["id"],
      project[:name],
      project["name"],
      project[:slug],
      project["slug"]
    ]
    |> normalized_keys()
  end

  defp entry_project_keys(_project), do: []

  defp project_match_keys(%ProjectConfig{} = project) do
    [project.id, project.name, project.tracker_project_slug]
    |> normalized_keys()
  end

  defp normalized_keys(keys) do
    keys
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp recent_failures(retrying) do
    retrying
    |> Enum.filter(&(is_binary(&1.error) and &1.error != ""))
    |> Enum.take(5)
    |> Enum.map(fn retry ->
      %{
        issue_identifier: retry.issue_identifier,
        attempt: retry.attempt,
        due_at: retry.due_at,
        error: retry.error,
        workspace_path: retry.workspace_path
      }
    end)
  end

  defp retry_pressure([]) do
    %{level: "none", retrying: 0, max_attempt: 0}
  end

  defp retry_pressure(retrying) do
    attempts = Enum.map(retrying, &(&1.attempt || 0))
    max_attempt = if attempts == [], do: 0, else: Enum.max(attempts)

    %{
      level: retry_pressure_level(length(retrying), max_attempt),
      retrying: length(retrying),
      max_attempt: max_attempt
    }
  end

  defp retry_pressure_level(retrying_count, max_attempt) when retrying_count >= 3 or max_attempt >= 3, do: "high"
  defp retry_pressure_level(_retrying_count, _max_attempt), do: "elevated"

  defp find_project(project_id, projects) do
    normalized_project_id = normalize_project_key(project_id)

    Enum.find(projects, fn %ProjectConfig{} = project ->
      normalized_project_id in project_match_keys(project)
    end)
  end

  defp normalize_project_key(project_id) when is_binary(project_id) do
    project_id
    |> String.trim()
    |> String.downcase()
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp project_from_entries(running, retry) do
    project_payload((running && Map.get(running, :project)) || (retry && Map.get(retry, :project)))
  end

  defp project_payload(nil), do: nil

  defp project_payload(project) when is_map(project) do
    %{
      id: project[:id] || project["id"],
      name: project[:name] || project["name"],
      slug: project[:slug] || project["slug"] || project[:slug_id] || project["slug_id"] || project["slugId"]
    }
  end

  defp project_payload(_project), do: nil

  defp current_turn_payload(running, retry) do
    %{
      session_id: (running && Map.get(running, :session_id)) || (retry && Map.get(retry, :session_id)),
      turn_id: running && Map.get(running, :current_turn_id),
      turn_count: (running && Map.get(running, :turn_count, 0)) || 0,
      last_event: running && Map.get(running, :last_codex_event),
      last_event_at: running && iso8601(Map.get(running, :last_codex_timestamp))
    }
  end

  defp runtime_payload(running, retry) do
    %{
      seconds: running && Map.get(running, :runtime_seconds),
      started_at: running && iso8601(Map.get(running, :started_at)),
      retry_due_at: retry && due_at_iso8601(retry.due_in_ms)
    }
  end

  defp tokens_payload(nil), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp tokens_payload(running) do
    %{
      input_tokens: Map.get(running, :codex_input_tokens, 0),
      output_tokens: Map.get(running, :codex_output_tokens, 0),
      total_tokens: Map.get(running, :codex_total_tokens, 0)
    }
  end

  defp source_control_payload(running, retry) do
    %{
      branch_name: (running && Map.get(running, :branch_name)) || (retry && Map.get(retry, :branch_name)),
      issue_url: (running && Map.get(running, :issue_url)) || (retry && Map.get(retry, :issue_url)),
      pr_url: nil
    }
  end

  defp timeline_payload(running, retry) do
    running_events =
      running
      |> event_history()
      |> Enum.map(&timeline_event_payload/1)

    retry_events =
      retry_history_payload(running, retry)
      |> Enum.map(&retry_timeline_event/1)

    running_events ++ retry_events
  end

  defp event_history(nil), do: []

  defp event_history(running) do
    case Map.get(running, :event_history, []) do
      [_ | _] = history ->
        history

      _ ->
        recent_events_payload(running)
    end
  end

  defp timeline_event_payload(event) when is_map(event) do
    summary = event_summary(event)

    %{
      at: iso8601(event_field(event, :at)),
      event: sanitize_text(event_field(event, :event)),
      category: sanitize_text(event_field(event, :category) || "event"),
      summary: sanitize_text(summary),
      turn_id: sanitize_text(event_field(event, :turn_id)),
      details: sanitize_text(event_field(event, :details) || summary)
    }
  end

  defp event_summary(event) do
    event_field(event, :summary) || event_field(event, :message) || event_field(event, :event)
  end

  defp event_field(event, key) when is_map(event) and is_atom(key) do
    event[key] || event[Atom.to_string(key)]
  end

  defp retry_timeline_event(event) do
    %{
      at: iso8601(event.scheduled_at),
      event: "retry_scheduled",
      category: "retry",
      summary: retry_summary(event),
      turn_id: nil,
      details: retry_summary(event)
    }
  end

  defp retry_summary(%{attempt: attempt, error: error, delay_ms: delay_ms}) do
    "retry attempt #{attempt} scheduled after #{delay_ms}ms" <>
      if(is_binary(error) and error != "", do: ": #{sanitize_text(error)}", else: "")
  end

  defp retry_history_payload(running, retry) do
    history =
      (running && Map.get(running, :retry_history)) ||
        (retry && Map.get(retry, :retry_history)) ||
        []

    history
    |> Enum.map(&retry_history_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp retry_history_entry(entry) when is_map(entry) do
    %{
      attempt: integer_or_zero(entry[:attempt] || entry["attempt"]),
      scheduled_at: entry[:scheduled_at] || entry["scheduled_at"],
      due_at: due_at_wall_ms_iso8601(entry[:due_at_wall_ms] || entry["due_at_wall_ms"]),
      delay_ms: integer_or_zero(entry[:delay_ms] || entry["delay_ms"]),
      delay_type: sanitize_text(entry[:delay_type] || entry["delay_type"]),
      error: sanitize_text(entry[:error] || entry["error"])
    }
  end

  defp retry_history_entry(_entry), do: nil

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        category: "event",
        summary: summarize_message(running.last_codex_message),
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp log_links_payload(workspace_path, worker_host) do
    links =
      [
        Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file()),
        workspace_log_path(workspace_path, worker_host)
      ]
      |> existing_file_links("log")

    %{
      codex_session_logs: links,
      empty_state: if(links == [], do: @log_empty_state, else: nil)
    }
  end

  defp workspace_log_path(workspace_path, nil) when is_binary(workspace_path), do: Path.join(workspace_path, "log/orchestrum.log")
  defp workspace_log_path(_workspace_path, _worker_host), do: nil

  defp evidence_links_payload(workspace_path, worker_host) do
    links =
      workspace_path
      |> evidence_candidates(worker_host)
      |> existing_file_links("evidence")

    %{
      items: links,
      empty_state: if(links == [], do: @evidence_empty_state, else: nil)
    }
  end

  defp evidence_candidates(workspace_path, nil) when is_binary(workspace_path) do
    @evidence_globs
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(workspace_path, pattern)) end)
  end

  defp evidence_candidates(_workspace_path, _worker_host), do: []

  defp existing_file_links(paths, kind) do
    paths
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&file_link(&1, kind))
    |> Enum.sort_by(& &1.updated_sort, :desc)
    |> Enum.take(@link_limit)
    |> Enum.map(&Map.delete(&1, :updated_sort))
  end

  defp file_link(path, kind) do
    updated_sort = file_updated_sort(path)

    %{
      label: Path.basename(path),
      kind: kind,
      path: path,
      href: "file://" <> URI.encode(path),
      updated_at: updated_at_iso8601(path),
      updated_sort: updated_sort
    }
  end

  defp file_updated_sort(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) -> mtime
      _ -> 0
    end
  end

  defp updated_at_iso8601(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) ->
        mtime
        |> DateTime.from_unix!()
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      _ ->
        nil
    end
  end

  defp mcp_server_payloads(running_entries) when is_list(running_entries) do
    running_entries
    |> Enum.flat_map(fn entry ->
      entry
      |> mcp_servers_for_entry()
      |> Enum.map(&Map.merge(&1, mcp_issue_context(entry)))
    end)
    |> Enum.sort_by(fn server ->
      {String.downcase(server.name || ""), server.issue_identifier || ""}
    end)
  end

  defp mcp_server_payloads(_running_entries), do: []

  defp mcp_servers_for_entry(entry) when is_map(entry) do
    entry
    |> Map.get(:mcp_servers, [])
    |> normalize_mcp_servers()
  end

  defp mcp_servers_for_entry(_entry), do: []

  defp normalize_mcp_servers(servers) when is_map(servers), do: servers |> Map.values() |> normalize_mcp_servers()

  defp normalize_mcp_servers(servers) when is_list(servers) do
    servers
    |> Enum.map(&mcp_server_payload/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn server -> String.downcase(server.name || "") end)
  end

  defp normalize_mcp_servers(_servers), do: []

  defp mcp_server_payload(server) when is_map(server) do
    name = server |> map_value(["name", :name]) |> string_or_nil()

    if is_nil(name) do
      nil
    else
      status = server |> map_value(["status", :status]) |> string_or_nil()
      detail = server |> map_value(["detail", :detail, "message", :message, "error", :error]) |> string_or_nil()

      %{
        name: name,
        status: status || "updated",
        detail: detail,
        action: server |> map_value(["action", :action]) |> string_or_nil() || mcp_action(status, detail),
        updated_at: server |> map_value(["updated_at", :updated_at]) |> timestamp_payload()
      }
    end
  end

  defp mcp_server_payload(_server), do: nil

  defp mcp_issue_context(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier)
    }
  end

  defp mcp_action(status, detail) do
    text =
      [status, detail]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      text == "" ->
        nil

      String.contains?(text, ["auth", "oauth", "credential", "login", "token", "permission", "unauthorized"]) ->
        "re_auth"

      String.contains?(text, ["config", "missing", "not found", "failed", "error", "invalid"]) ->
        "re_config"

      true ->
        nil
    end
  end

  defp summarize_message(nil), do: nil

  defp summarize_message(message) do
    message
    |> StatusDashboard.humanize_codex_message()
    |> sanitize_text()
  end

  defp sanitize_text(nil), do: nil

  defp sanitize_text(value) do
    value
    |> to_string()
    |> String.replace(~r/(?i)\b(bearer)\s+[a-z0-9._~+\/=-]+/, "\\1 [redacted]")
    |> String.replace(~r/(?i)\b(authorization)\s*[:=]\s*([^\s,;]+)/, "\\1=[redacted]")
    |> String.replace(~r/(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|ACCESS_KEY|PRIVATE_KEY)[A-Z0-9_]*)=([^\s,;]+)/, "\\1=[redacted]")
    |> String.replace(~r/(?i)\b(api[_-]?key|token|secret|password|access[_-]?token|refresh[_-]?token)\s*[:=]\s*([^\s,;]+)/, "\\1=[redacted]")
    |> String.replace(~r/\b(sk-[A-Za-z0-9_-]{6,}|gh[pousr]_[A-Za-z0-9_]{6,})\b/, "[redacted]")
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp due_at_wall_ms_iso8601(due_at_wall_ms) when is_integer(due_at_wall_ms) do
    due_at_wall_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_wall_ms_iso8601(_due_at_wall_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(datetime) when is_binary(datetime), do: datetime
  defp iso8601(_datetime), do: nil

  defp default_controls do
    %{polling_paused: false, paused_projects: [], pending_dispatch_projects: []}
  end

  defp control_result(:unavailable), do: {:error, :unavailable}
  defp control_result(payload) when is_map(payload), do: {:ok, encode_datetimes(payload)}

  defp encode_datetimes(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp encode_datetimes(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {key, encode_datetimes(nested_value)} end)
  end

  defp encode_datetimes(values) when is_list(values), do: Enum.map(values, &encode_datetimes/1)
  defp encode_datetimes(value), do: value

  defp integer_or_zero(value) when is_integer(value), do: value

  defp integer_or_zero(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp integer_or_zero(_value), do: 0

  defp timestamp_payload(value), do: iso8601(value) || string_or_nil(value)

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(nil), do: nil
  defp string_or_nil(value) when is_atom(value), do: value |> Atom.to_string() |> string_or_nil()
  defp string_or_nil(value) when is_integer(value), do: Integer.to_string(value)
  defp string_or_nil(value) when is_float(value), do: Float.to_string(value)
  defp string_or_nil(value) when is_map(value) or is_list(value), do: inspect(value)
  defp string_or_nil(_value), do: nil

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_value(_map, _keys), do: nil
end
