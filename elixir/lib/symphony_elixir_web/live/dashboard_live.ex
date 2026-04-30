defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Orchestrum.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, ProjectRegistry}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(params, _session, socket) do
    selected_issue_identifier = params["issue_identifier"]

    socket =
      socket
      |> assign(:selected_issue_identifier, selected_issue_identifier)
      |> assign(:event_query, "")
      |> assign(:payload, load_payload(selected_issue_identifier))
      |> assign(:now, DateTime.utc_now())
      |> assign(:refresh_notice, nil)
      |> assign(:show_project_form, false)
      |> assign(:project_form, default_project_form())
      |> assign(:project_form_error, nil)
      |> assign(:project_form_notice, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload(socket.assigns.selected_issue_identifier))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    notice =
      case Presenter.refresh_payload(orchestrator()) do
        {:ok, %{coalesced: true}} -> "Refresh already queued"
        {:ok, _payload} -> "Refresh queued"
        {:error, :unavailable} -> "Orchestrator unavailable"
      end

    {:noreply,
     socket
     |> assign(:payload, load_payload(socket.assigns.selected_issue_identifier))
     |> assign(:now, DateTime.utc_now())
     |> assign(:refresh_notice, notice)}
  end

  @impl true
  def handle_event("filter_events", %{"timeline" => %{"query" => query}}, socket) do
    {:noreply, assign(socket, :event_query, query || "")}
  end

  def handle_event("filter_events", _params, socket) do
    {:noreply, assign(socket, :event_query, "")}
  end

  @impl true
  def handle_event("show_project_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_project_form, true)
     |> assign(:project_form_error, nil)
     |> assign(:project_form_notice, nil)}
  end

  @impl true
  def handle_event("cancel_project_form", _params, socket) do
    {:noreply, reset_project_form(socket)}
  end

  @impl true
  def handle_event("add_project", %{"project" => project_params}, socket) do
    case ProjectRegistry.add_project(project_params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> reset_project_form()
         |> assign(:payload, load_payload(socket.assigns.selected_issue_identifier))
         |> assign(:now, DateTime.utc_now())
         |> assign(:project_form_notice, "#{project.name} added")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_project_form, true)
         |> assign(:project_form, project_form(project_params))
         |> assign(:project_form_error, project_error(reason))
         |> assign(:project_form_notice, nil)}
    end
  end

  def handle_event("add_project", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_project_form, true)
     |> assign(:project_form_error, project_error(:invalid_project_input))
     |> assign(:project_form_notice, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Orchestrum Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Orchestrum runtime.
            </p>
          </div>

          <div class="status-stack">
            <button type="button" class="subtle-button" phx-click="refresh_now">
              Refresh now
            </button>
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
            <%= if @refresh_notice do %>
              <span class="muted"><%= @refresh_notice %></span>
            <% end %>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Next poll</p>
            <p class="metric-value numeric"><%= format_polling(@payload.polling) %></p>
            <p class="metric-detail">Poll interval <%= format_poll_interval(@payload.polling) %>.</p>
          </article>
        </section>

        <%= if @payload.selected_detail do %>
          <section class="section-card run-detail-card">
            <%= if @payload.selected_detail[:error] do %>
              <div class="section-header">
                <div>
                  <h2 class="section-title">Run details</h2>
                  <p class="section-copy"><%= @payload.selected_detail.error.message %></p>
                </div>
                <a class="issue-link" href="/">Dashboard</a>
              </div>
            <% else %>
              <% detail = @payload.selected_detail %>
              <% timeline_events = filtered_timeline(detail.timeline, @event_query) %>

              <div class="section-header">
                <div>
                  <h2 class="section-title"><%= detail.issue_identifier %> run details</h2>
                  <p class="section-copy">
                    <%= detail.status %> · <%= project_label(detail.project) %>
                  </p>
                </div>
                <a class="issue-link" href="/">Dashboard</a>
              </div>

              <dl class="detail-kv-grid">
                <div>
                  <dt>Status</dt>
                  <dd><%= detail.status %></dd>
                </div>
                <div>
                  <dt>Runtime</dt>
                  <dd class="numeric"><%= runtime_detail(detail.runtime) %></dd>
                </div>
                <div>
                  <dt>Current turn</dt>
                  <dd class="numeric"><%= current_turn_detail(detail.current_turn) %></dd>
                </div>
                <div>
                  <dt>Tokens</dt>
                  <dd class="numeric">
                    <%= format_int(detail.tokens.total_tokens) %>
                    <span class="muted">In <%= format_int(detail.tokens.input_tokens) %> / Out <%= format_int(detail.tokens.output_tokens) %></span>
                  </dd>
                </div>
                <div>
                  <dt>Workspace host</dt>
                  <dd><%= format_optional(detail.workspace.host || "local") %></dd>
                </div>
                <div>
                  <dt>Workspace path</dt>
                  <dd class="mono wrap-anywhere"><%= detail.workspace.path %></dd>
                </div>
                <div>
                  <dt>Branch</dt>
                  <dd class="mono wrap-anywhere"><%= format_optional(detail.source_control.branch_name) %></dd>
                </div>
                <div>
                  <dt>PR</dt>
                  <dd><%= format_optional(detail.source_control.pr_url) %></dd>
                </div>
              </dl>

              <div class="detail-columns">
                <section class="detail-panel">
                  <div class="detail-panel-header">
                    <h3>Timeline</h3>
                    <form id="timeline-search-form" phx-change="filter_events">
                      <input
                        type="search"
                        name="timeline[query]"
                        value={@event_query}
                        placeholder="Search timeline"
                        aria-label="Search timeline"
                        autocomplete="off"
                      />
                    </form>
                  </div>

                  <%= if timeline_events == [] do %>
                    <p class="empty-state">No matching events.</p>
                  <% else %>
                    <ol class="timeline-list">
                      <li :for={event <- timeline_events} class="timeline-item">
                        <details open={event_open?(event)}>
                          <summary>
                            <span class="timeline-category"><%= event.category %></span>
                            <span class="timeline-summary-text"><%= event.summary || event.event || "event" %></span>
                          </summary>
                          <div class="timeline-meta">
                            <span><%= event.event || "event" %></span>
                            <%= if event.turn_id do %>
                              <span>turn <span class="mono"><%= event.turn_id %></span></span>
                            <% end %>
                            <%= if event.at do %>
                              <span class="mono numeric"><%= event.at %></span>
                            <% end %>
                          </div>
                          <pre class="timeline-detail-body"><%= event.details || event.summary || "n/a" %></pre>
                        </details>
                      </li>
                    </ol>
                  <% end %>
                </section>

                <section class="detail-panel">
                  <h3>Retry history</h3>
                  <%= if detail.retry_history == [] do %>
                    <p class="empty-state">No retry attempts recorded.</p>
                  <% else %>
                    <ol class="compact-list">
                      <li :for={retry <- detail.retry_history}>
                        <span class="numeric">Attempt <%= retry.attempt %></span>
                        <span class="muted"><%= retry.due_at || "due time unavailable" %></span>
                        <span><%= retry.error || "no error recorded" %></span>
                      </li>
                    </ol>
                  <% end %>

                  <h3>Rate limits</h3>
                  <pre class="code-panel compact-code-panel"><%= pretty_value(detail.rate_limits) %></pre>
                </section>
              </div>

              <div class="detail-columns detail-columns-secondary">
                <section class="detail-panel">
                  <h3>Logs</h3>
                  <%= if detail.logs.codex_session_logs == [] do %>
                    <p class="empty-state"><%= detail.logs.empty_state %></p>
                  <% else %>
                    <ul class="link-list">
                      <li :for={link <- detail.logs.codex_session_logs}>
                        <a href={link.href}><%= link.label %></a>
                        <span class="muted mono"><%= link.updated_at || link.path %></span>
                      </li>
                    </ul>
                  <% end %>
                </section>

                <section class="detail-panel">
                  <h3>Evidence</h3>
                  <%= if detail.evidence.items == [] do %>
                    <p class="empty-state"><%= detail.evidence.empty_state %></p>
                  <% else %>
                    <ul class="link-list">
                      <li :for={link <- detail.evidence.items}>
                        <a href={link.href}><%= link.label %></a>
                        <span class="muted mono"><%= link.updated_at || link.path %></span>
                      </li>
                    </ul>
                  <% end %>
                </section>
              </div>
            <% end %>
          </section>
        <% end %>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Projects</h2>
              <p class="section-copy">Configured project, workspace, and repository context.</p>
            </div>
            <button type="button" class="icon-button" phx-click="show_project_form" aria-label="Add project" title="Add project">
              [+]
            </button>
          </div>

          <%= if @project_form_notice do %>
            <p class="form-notice"><%= @project_form_notice %></p>
          <% end %>

          <%= if @show_project_form do %>
            <form id="add-project-form" class="project-form" phx-submit="add_project">
              <div class="project-form-grid">
                <label>
                  <span>Project name</span>
                  <input name="project[name]" value={@project_form["name"] || ""} autocomplete="off" />
                </label>
                <label>
                  <span>Linear project slug</span>
                  <input name="project[project_slug]" value={@project_form["project_slug"] || ""} autocomplete="off" />
                </label>
              </div>
              <%= if @project_form_error do %>
                <p class="form-error"><%= @project_form_error %></p>
              <% end %>
              <div class="form-actions">
                <button type="submit">Add project</button>
                <button type="button" class="secondary" phx-click="cancel_project_form">Cancel</button>
              </div>
            </form>
          <% end %>

          <%= if @payload.projects == [] do %>
            <p class="empty-state">No configured projects.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Tracker</th>
                    <th>Workspace root</th>
                    <th>Repository</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={project <- @payload.projects}>
                    <td><%= project.name || project.id %></td>
                    <td><%= project.tracker_kind %> / <%= project.tracker_project_slug || "n/a" %></td>
                    <td class="mono"><%= project.workspace_root %></td>
                    <td class="mono"><%= project.repository_path || "default hook" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 10rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Project</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={entry.detail_path}>Details</a>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                      </div>
                    </td>
                    <td><%= project_label(entry.project) %></td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Project</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={entry.detail_path}>Details</a>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                      </div>
                    </td>
                    <td><%= project_label(entry.project) %></td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload(selected_issue_identifier) do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())

    selected_detail =
      case selected_issue_identifier do
        identifier when is_binary(identifier) and identifier != "" ->
          case Presenter.issue_payload(identifier, orchestrator(), snapshot_timeout_ms()) do
            {:ok, detail} -> detail
            {:error, :issue_not_found} -> %{error: %{code: "issue_not_found", message: "Issue not found"}}
          end

        _ ->
          nil
      end

    Map.put(payload, :selected_detail, selected_detail)
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || Config.snapshot_timeout_ms()
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_polling(%{checking?: true}), do: "checking"
  defp format_polling(%{next_poll_in_ms: ms}) when is_integer(ms), do: format_runtime_seconds(ms / 1_000)
  defp format_polling(_polling), do: "n/a"

  defp format_poll_interval(%{poll_interval_ms: ms}) when is_integer(ms), do: format_runtime_seconds(ms / 1_000)
  defp format_poll_interval(_polling), do: "n/a"

  defp runtime_detail(%{seconds: seconds}) when is_number(seconds), do: format_runtime_seconds(seconds)
  defp runtime_detail(%{retry_due_at: due_at}) when is_binary(due_at), do: "retry due #{due_at}"
  defp runtime_detail(_runtime), do: "n/a"

  defp current_turn_detail(%{turn_count: count, turn_id: turn_id}) when is_integer(count) and is_binary(turn_id) do
    "#{count} / #{turn_id}"
  end

  defp current_turn_detail(%{turn_count: count}) when is_integer(count) and count > 0, do: Integer.to_string(count)
  defp current_turn_detail(%{session_id: session_id}) when is_binary(session_id), do: session_id
  defp current_turn_detail(_current_turn), do: "n/a"

  defp format_optional(value) when is_binary(value) and value != "", do: value
  defp format_optional(_value), do: "n/a"

  defp filtered_timeline(events, query) when is_list(events) and is_binary(query) do
    normalized_query = query |> String.trim() |> String.downcase()

    if normalized_query == "" do
      events
    else
      Enum.filter(events, fn event ->
        event
        |> timeline_search_text()
        |> String.downcase()
        |> String.contains?(normalized_query)
      end)
    end
  end

  defp filtered_timeline(events, _query) when is_list(events), do: events
  defp filtered_timeline(_events, _query), do: []

  defp timeline_search_text(event) when is_map(event) do
    [event[:category], event[:event], event[:summary], event[:details], event[:turn_id]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp event_open?(%{summary: summary}) when is_binary(summary), do: String.length(summary) <= 180
  defp event_open?(_event), do: true

  defp project_label(nil), do: "n/a"
  defp project_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp project_label(%{id: id}) when is_binary(id) and id != "", do: id
  defp project_label(project) when is_map(project), do: project[:slug] || "n/a"
  defp project_label(_project), do: "n/a"

  defp default_project_form, do: %{"name" => "", "project_slug" => ""}

  defp project_form(params) when is_map(params) do
    %{
      "name" => params["name"] || "",
      "project_slug" => params["project_slug"] || params["tracker_project_slug"] || ""
    }
  end

  defp reset_project_form(socket) do
    socket
    |> assign(:show_project_form, false)
    |> assign(:project_form, default_project_form())
    |> assign(:project_form_error, nil)
  end

  defp project_error(:project_name_required), do: "Project name is required."
  defp project_error(:project_slug_required), do: "Linear project slug is required."
  defp project_error(:duplicate_project), do: "Project is already configured."
  defp project_error(:invalid_project_input), do: "Project name and Linear project slug are required."
  defp project_error({:workflow_write_failed, _reason}), do: "Could not update WORKFLOW.md."
  defp project_error({:workflow_reload_failed, _reason}), do: "Could not reload WORKFLOW.md."
  defp project_error(_reason), do: "Could not add project."

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
