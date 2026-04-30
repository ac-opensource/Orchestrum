defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, ProjectConfig, StatusDashboard}

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
          polling: snapshot.polling,
          last_poll_result: Map.get(snapshot, :last_poll_result),
          running: running,
          retrying: retrying,
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
end
