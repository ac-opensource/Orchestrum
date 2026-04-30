defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, ProjectConfig, StatusDashboard, Tracker}

  @task_board_default_limit 50
  @task_board_max_limit 100

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          projects: Enum.map(Config.project_configs(), &ProjectConfig.summary/1),
          mcp_servers: mcp_server_payloads(snapshot.running),
          polling: snapshot.polling,
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
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
          {:ok, issue_payload_body(issue_identifier, running, retry)}
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
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
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

  @spec control_payload(String.t(), map(), GenServer.name()) ::
          {:ok, pos_integer(), map()} | {:error, pos_integer(), map()}
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

  defp issue_payload_body(issue_identifier, running, retry) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry),
      status: issue_status(running, retry),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      project: project_from_entries(running, retry),
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(_running, nil), do: "running"
  defp issue_status(nil, _retry), do: "retrying"
  defp issue_status(_running, _retry), do: "running"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      project: project_payload(Map.get(entry, :project)),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
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
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      project: project_payload(Map.get(entry, :project)),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      project: project_payload(Map.get(running, :project)),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
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
      error: retry.error,
      project: project_payload(Map.get(retry, :project)),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
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

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
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
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

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
