defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, LogFile, Orchestrator, ProjectConfig, StatusDashboard}

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
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

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

  defp integer_or_zero(value) when is_integer(value), do: value

  defp integer_or_zero(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp integer_or_zero(_value), do: 0
end
