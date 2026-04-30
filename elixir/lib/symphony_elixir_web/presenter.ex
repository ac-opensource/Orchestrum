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
        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying)
          },
          projects: Enum.map(Config.project_configs(), &ProjectConfig.summary/1),
          polling: Map.put_new(snapshot.polling, :paused?, false),
          controls: Map.get(snapshot, :controls, default_controls()),
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
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
        {:ok, encode_datetimes(payload)}
    end
  end

  @spec control_payload(GenServer.name(), String.t()) ::
          {:ok, map()} | {:error, :unavailable}
  def control_payload(orchestrator, action), do: control_payload(orchestrator, action, nil)

  @spec control_payload(GenServer.name(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :unavailable}
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

  def control_payload(_orchestrator, action, target) do
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
end
