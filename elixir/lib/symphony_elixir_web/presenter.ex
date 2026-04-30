defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Linear.Issue, Orchestrator, ProjectConfig, StatusDashboard, Tracker}

  @task_board_primary_states ["Todo", "In Progress", "Human Review", "Rework", "Merging", "Done"]
  @task_board_group_defs [
    %{id: "todo", title: "Todo", states: ["todo"]},
    %{id: "in_progress", title: "In Progress", states: ["in progress"]},
    %{id: "human_review", title: "Human Review", states: ["human review"]},
    %{id: "rework", title: "Rework", states: ["rework"]},
    %{id: "merging", title: "Merging", states: ["merging"]},
    %{id: "done", title: "Done / terminal", states: ["done"]}
  ]
  @empty_task_board_filters %{project: "", state: "", label: "", query: "", status: ""}
  @task_board_default_limit 50
  @task_board_max_limit 100

  @spec state_payload(GenServer.name(), timeout()) :: map()
  @spec state_payload(GenServer.name(), timeout(), map()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms, task_board_filters \\ %{}) do
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
          task_board: dashboard_task_board_payload(snapshot, task_board_filters),
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

  @spec normalize_task_board_filters(map()) :: map()
  def normalize_task_board_filters(filters) when is_map(filters) do
    %{
      project: string_filter(filters, :project),
      state: string_filter(filters, :state),
      label: string_filter(filters, :label),
      query: string_filter(filters, :query),
      status: string_filter(filters, :status)
    }
  end

  def normalize_task_board_filters(_filters), do: @empty_task_board_filters

  @doc false
  @spec task_board_payload_for_test([Issue.t()], map(), map(), DateTime.t()) :: map()
  def task_board_payload_for_test(issues, snapshot, filters, %DateTime{} = now)
      when is_list(issues) and is_map(snapshot) and is_map(filters) do
    build_task_board_payload(issues, snapshot, filters, now)
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        task_issue = task_issue_payload_by_identifier(snapshot, issue_identifier)

        if is_nil(running) and is_nil(retry) and is_nil(task_issue) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, task_issue)}
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

  defp issue_payload_body(issue_identifier, running, retry, task_issue) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_payload_id(running, retry, task_issue),
      status: issue_status(running, retry, task_issue),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      },
      project: issue_payload_project(running, retry, task_issue),
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: maybe_running_payload(running),
      retry: maybe_retry_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: maybe_recent_events_payload(running),
      last_error: retry_error(retry),
      tracked: task_issue || %{}
    }
  end

  defp issue_id_from_entries(running, retry),
    do: (running && running.issue_id) || (retry && retry.issue_id)

  defp issue_payload_id(running, retry, task_issue) do
    issue_id_from_entries(running, retry) || (task_issue && task_issue.issue_id)
  end

  defp issue_payload_project(running, retry, task_issue) do
    project_from_entries(running, retry) || (task_issue && task_issue.project)
  end

  defp maybe_running_payload(nil), do: nil
  defp maybe_running_payload(running), do: running_issue_payload(running)

  defp maybe_retry_payload(nil), do: nil
  defp maybe_retry_payload(retry), do: retry_issue_payload(retry)

  defp maybe_recent_events_payload(nil), do: []
  defp maybe_recent_events_payload(running), do: recent_events_payload(running)

  defp retry_error(nil), do: nil
  defp retry_error(retry), do: retry.error

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(nil, nil, _task_issue), do: "tracked"
  defp issue_status(_running, nil, _task_issue), do: "running"
  defp issue_status(nil, _retry, _task_issue), do: "retrying"
  defp issue_status(_running, _retry, _task_issue), do: "running"

  defp dashboard_task_board_payload(snapshot, filters) when is_map(snapshot) do
    now = DateTime.utc_now()

    case fetch_task_board_issues(task_board_state_names()) do
      {:ok, issues} -> build_task_board_payload(issues, snapshot, filters, now)
      {:error, reason} -> empty_task_board_payload(filters, reason)
    end
  end

  defp task_issue_payload_by_identifier(snapshot, issue_identifier) do
    %{issues: issues} = dashboard_task_board_payload(snapshot, %{})

    Enum.find(issues, fn issue ->
      issue.issue_identifier == issue_identifier || issue.issue_id == issue_identifier
    end)
  end

  defp build_task_board_payload(issues, snapshot, filters, now) do
    filters = normalize_task_board_filters(filters)
    terminal_states = terminal_state_set()
    runtime_index = runtime_status_index(snapshot)

    all_issues =
      issues
      |> Enum.map(&task_issue_payload(&1, runtime_index, terminal_states, now))
      |> Enum.sort_by(&task_issue_sort_key/1)

    filtered_issues = Enum.filter(all_issues, &task_issue_matches_filters?(&1, filters))

    %{
      filters: filters,
      groups: task_board_groups(filtered_issues, terminal_states),
      issues: filtered_issues,
      total_count: length(all_issues),
      filtered_count: length(filtered_issues),
      options: task_board_filter_options(all_issues),
      error: nil
    }
  end

  defp empty_task_board_payload(filters, reason) do
    filters = normalize_task_board_filters(filters)

    %{
      filters: filters,
      groups: empty_task_board_groups(),
      issues: [],
      total_count: 0,
      filtered_count: 0,
      options: task_board_filter_options([]),
      error: %{
        code: "task_board_unavailable",
        message: "Task board tracker read failed: #{inspect(reason)}"
      }
    }
  end

  defp fetch_task_board_issues(state_names) do
    case Application.get_env(:symphony_elixir, :task_board_fetcher) do
      fetcher when is_function(fetcher, 1) -> fetcher.(state_names)
      _ -> Tracker.fetch_issues_by_states(state_names)
    end
  end

  defp task_board_state_names do
    project_states =
      Config.project_configs()
      |> Enum.flat_map(fn project -> project.active_states ++ project.terminal_states end)

    (@task_board_primary_states ++ project_states)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.uniq_by(&normalize_state/1)
  end

  defp task_issue_payload(issue, runtime_index, terminal_states, now) do
    issue_id = issue_value(issue, :id)
    identifier = issue_value(issue, :identifier)
    state = issue_value(issue, :state) || "Unknown"
    project = project_payload(issue_value(issue, :project))
    labels = issue_labels(issue)
    created_at = issue_value(issue, :created_at)
    updated_at = issue_value(issue, :updated_at)
    blocked_by = issue_blockers(issue)
    run_status = runtime_status_for(runtime_index, issue_id, identifier)
    assignee = assignee_label(issue)

    %{
      issue_id: issue_id,
      issue_identifier: identifier,
      title: issue_value(issue, :title) || identifier || "Untitled issue",
      state: state,
      project: project,
      project_label: project_label(project),
      project_filter_values: project_filter_values(project),
      assignee: assignee,
      labels: labels,
      created_at: iso8601(created_at),
      updated_at: iso8601(updated_at),
      age_label: relative_time_label(created_at, now),
      updated_label: relative_time_label(updated_at, now),
      relations: relation_payload(blocked_by, terminal_states),
      run_status: run_status,
      url: issue_value(issue, :url),
      search_text: search_text(identifier, issue_value(issue, :title), state, project, assignee, labels, run_status)
    }
  end

  defp task_issue_sort_key(issue) do
    {task_group_index(issue.state), -timestamp_sort_value(issue.updated_at), issue.issue_identifier || ""}
  end

  defp task_group_index(state) do
    normalized = normalize_state(state)

    @task_board_group_defs
    |> Enum.find_index(fn group -> normalized in group.states end)
    |> case do
      nil -> length(@task_board_group_defs)
      index -> index
    end
  end

  defp task_issue_matches_filters?(issue, filters) do
    filter_match?(filters.project, issue.project_filter_values) and
      filter_match?(filters.state, [issue.state]) and
      filter_match?(filters.label, issue.labels) and
      status_filter_match?(filters.status, issue) and
      query_filter_match?(filters.query, issue.search_text)
  end

  defp filter_match?("", _values), do: true

  defp filter_match?(filter, values) when is_list(values) do
    normalized_filter = normalize_state(filter)
    Enum.any?(values, &(normalize_state(&1) == normalized_filter))
  end

  defp status_filter_match?("", _issue), do: true
  defp status_filter_match?("active", issue), do: issue.run_status.status == "active"
  defp status_filter_match?("retry", issue), do: issue.run_status.status == "retrying"

  defp status_filter_match?("review", issue) do
    normalize_state(issue.state) in ["human review", "rework"]
  end

  defp status_filter_match?(_status, _issue), do: true

  defp query_filter_match?("", _search_text), do: true

  defp query_filter_match?(query, search_text) do
    String.contains?(search_text, String.downcase(query))
  end

  defp task_board_groups(issues, terminal_states) do
    grouped = Enum.group_by(issues, &task_group_id(&1, terminal_states))

    @task_board_group_defs
    |> Enum.map(fn group ->
      group_issues = Map.get(grouped, group.id, [])

      %{
        id: group.id,
        title: group.title,
        count: length(group_issues),
        issues: group_issues
      }
    end)
    |> maybe_append_other_group(grouped)
  end

  defp empty_task_board_groups do
    Enum.map(@task_board_group_defs, fn group ->
      %{id: group.id, title: group.title, count: 0, issues: []}
    end)
  end

  defp maybe_append_other_group(groups, grouped) do
    other_issues = Map.get(grouped, "other", [])

    if other_issues == [] do
      groups
    else
      groups ++ [%{id: "other", title: "Other", count: length(other_issues), issues: other_issues}]
    end
  end

  defp task_group_id(issue, terminal_states) do
    normalized = normalize_state(issue.state)

    cond do
      Enum.any?(@task_board_group_defs, &(normalized in &1.states)) ->
        @task_board_group_defs
        |> Enum.find(&(normalized in &1.states))
        |> Map.fetch!(:id)

      MapSet.member?(terminal_states, normalized) ->
        "done"

      true ->
        "other"
    end
  end

  defp task_board_filter_options(issues) do
    %{
      projects:
        issues
        |> Enum.map(& &1.project_label)
        |> option_values(),
      states:
        (@task_board_primary_states ++ Enum.map(issues, & &1.state))
        |> option_values(),
      labels:
        issues
        |> Enum.flat_map(& &1.labels)
        |> option_values(),
      statuses: [
        %{value: "", label: "All runtime statuses"},
        %{value: "active", label: "Active"},
        %{value: "retry", label: "Retrying"},
        %{value: "review", label: "Review / rework"}
      ]
    }
  end

  defp option_values(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(String.trim(&1) == "" or &1 == "n/a"))
    |> Enum.uniq_by(&normalize_state/1)
    |> Enum.map(&%{value: &1, label: &1})
  end

  defp runtime_status_index(snapshot) do
    running = Map.get(snapshot, :running, [])
    retrying = Map.get(snapshot, :retrying, [])

    retry_index =
      retrying
      |> Enum.map(fn entry ->
        status = %{
          status: "retrying",
          label: "Retrying",
          attempt: Map.get(entry, :attempt),
          error: Map.get(entry, :error),
          due_at: due_at_iso8601(Map.get(entry, :due_in_ms)),
          workspace_path: Map.get(entry, :workspace_path)
        }

        runtime_index_entries(entry, status)
      end)
      |> List.flatten()
      |> Map.new()

    running
    |> Enum.map(fn entry ->
      status = %{
        status: "active",
        label: "Running",
        session_id: Map.get(entry, :session_id),
        turn_count: Map.get(entry, :turn_count, 0),
        started_at: iso8601(Map.get(entry, :started_at)),
        workspace_path: Map.get(entry, :workspace_path)
      }

      runtime_index_entries(entry, status)
    end)
    |> List.flatten()
    |> Map.new()
    |> Map.merge(retry_index, fn _key, running_status, _retry_status -> running_status end)
  end

  defp runtime_index_entries(entry, status) when is_map(entry) do
    [
      {Map.get(entry, :issue_id), status},
      {Map.get(entry, :identifier), status}
    ]
    |> Enum.reject(fn {key, _value} -> is_nil(key) end)
  end

  defp runtime_status_for(runtime_index, issue_id, identifier) do
    Map.get(runtime_index, issue_id) ||
      Map.get(runtime_index, identifier) ||
      %{status: "idle", label: "No current run"}
  end

  defp relation_payload(blocked_by, terminal_states) do
    active_blockers =
      Enum.reject(blocked_by, fn blocker ->
        MapSet.member?(terminal_states, normalize_state(blocker[:state] || blocker["state"]))
      end)

    %{
      blocked: active_blockers != [],
      blocked_by: blocked_by,
      label: relation_label(blocked_by, active_blockers)
    }
  end

  defp relation_label([], _active_blockers), do: "No blockers"

  defp relation_label(_blocked_by, active_blockers) when active_blockers != [] do
    active_blockers
    |> Enum.map(&(&1[:identifier] || &1["identifier"] || &1[:id] || &1["id"]))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Blocked"
      identifiers -> "Blocked by #{Enum.join(identifiers, ", ")}"
    end
  end

  defp relation_label(_blocked_by, _active_blockers), do: "Blockers done"

  defp issue_value(%Issue{} = issue, key), do: Map.get(issue, key)
  defp issue_value(%{} = issue, key), do: Map.get(issue, key) || Map.get(issue, Atom.to_string(key))
  defp issue_value(_issue, _key), do: nil

  defp issue_labels(%Issue{} = issue), do: Issue.label_names(issue)
  defp issue_labels(%{} = issue), do: Map.get(issue, :labels) || Map.get(issue, "labels") || []
  defp issue_labels(_issue), do: []

  defp issue_blockers(issue) do
    case issue_value(issue, :blocked_by) do
      blockers when is_list(blockers) -> blockers
      _ -> []
    end
  end

  defp assignee_label(issue) do
    issue_value(issue, :assignee_name) || issue_value(issue, :assignee_id)
  end

  defp search_text(identifier, title, state, project, assignee, labels, run_status) do
    [
      identifier,
      title,
      state,
      project_label(project),
      assignee,
      labels,
      run_status.label,
      run_status.status
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp project_filter_values(nil), do: []

  defp project_filter_values(project) when is_map(project) do
    [project[:id], project[:name], project[:slug], project["id"], project["name"], project["slug"]]
    |> Enum.reject(&is_nil/1)
  end

  defp terminal_state_set do
    Config.project_configs()
    |> Enum.flat_map(& &1.terminal_states)
    |> Enum.concat(["Done", "Closed", "Cancelled", "Canceled", "Duplicate"])
    |> Enum.map(&normalize_state/1)
    |> MapSet.new()
  end

  defp string_filter(filters, key) do
    value = Map.get(filters, key) || Map.get(filters, Atom.to_string(key))

    case value do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  defp normalize_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(value), do: value |> to_string() |> normalize_state()

  defp timestamp_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end

  defp timestamp_sort_value(%DateTime{} = value), do: DateTime.to_unix(value)
  defp timestamp_sort_value(_value), do: 0

  defp relative_time_label(%DateTime{} = datetime, %DateTime{} = now) do
    diff_seconds = max(DateTime.diff(now, datetime, :second), 0)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3_600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3_600)}h ago"
      true -> "#{div(diff_seconds, 86_400)}d ago"
    end
  end

  defp relative_time_label(_datetime, _now), do: "n/a"

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

  defp project_label(nil), do: "n/a"
  defp project_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp project_label(%{id: id}) when is_binary(id) and id != "", do: id
  defp project_label(project) when is_map(project), do: project[:slug] || project["slug"] || "n/a"

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
