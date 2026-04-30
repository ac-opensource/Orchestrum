defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Orchestrum.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, ProjectRegistry, Tracker}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @dashboard_views [
    %{id: "overview", label: "Overview", path: "/"},
    %{id: "tasks", label: "Tasks", path: "/tasks"},
    %{id: "runs", label: "Runs", path: "/runs"},
    %{id: "projects", label: "Projects", path: "/projects"},
    %{id: "controls", label: "Controls", path: "/controls"},
    %{id: "settings", label: "Settings", path: "/settings"},
    %{id: "diagnostics", label: "Diagnostics", path: "/diagnostics"}
  ]
  @view_ids Enum.map(@dashboard_views, & &1.id)

  @impl true
  def mount(params, _session, socket) do
    selected_issue_identifier = params["issue_identifier"]

    socket =
      socket
      |> assign(:selected_issue_identifier, selected_issue_identifier)
      |> assign(:event_query, "")
      |> assign(:payload, load_payload(selected_issue_identifier))
      |> assign(:now, DateTime.utc_now())
      |> assign(:current_view, "overview")
      |> assign(:selected_project_id, "all")
      |> assign(:refresh_notice, nil)
      |> assign(:control_notice, nil)
      |> assign(:task_filter, "all")
      |> assign(:project_action_notice, nil)
      |> assign(:project_action_error, nil)
      |> assign(:show_project_form, false)
      |> assign(:project_form, default_project_form())
      |> assign(:project_form_error, nil)
      |> assign(:project_form_notice, nil)
      |> assign(:ticket_reply_errors, %{})
      |> assign(:ticket_reply_notices, %{})

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:current_view, view_from_params(params, socket.assigns.live_action))
     |> assign(:selected_project_id, selected_project_id(params, socket.assigns.payload))}
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
        {:ok, %{rejected: true, message: message}} -> message
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
  def handle_event("control", %{"action" => action} = params, socket) do
    target = params["target"]

    notice =
      case Presenter.control_payload(orchestrator(), action, target) do
        {:ok, payload} -> control_notice(payload)
        {:error, :unavailable} -> "Orchestrator unavailable"
      end

    {:noreply,
     socket
     |> assign(:payload, load_payload(socket.assigns.selected_issue_identifier))
     |> assign(:now, DateTime.utc_now())
     |> assign(:control_notice, notice)}
  end

  @impl true
  def handle_event("filter_project", %{"project" => project_id}, socket) do
    {:noreply, push_patch(socket, to: project_filter_path(project_id))}
  end

  @impl true
  def handle_event("refresh_project", %{"project-id" => project_id}, socket) do
    {notice, error} =
      case Presenter.project_refresh_payload(project_id, orchestrator()) do
        {:ok, %{coalesced: true, project: project}} ->
          {"#{project.name || project.id} refresh already queued", nil}

        {:ok, %{project: project}} ->
          {"#{project.name || project.id} refresh queued", nil}

        {:error, :project_not_found} ->
          {nil, "Project not found"}

        {:error, :unavailable} ->
          {nil, "Orchestrator unavailable"}
      end

    {:noreply,
     socket
     |> assign(:payload, load_payload(socket.assigns.selected_issue_identifier))
     |> assign(:now, DateTime.utc_now())
     |> assign(:project_action_notice, notice)
     |> assign(:project_action_error, error)}
  end

  @impl true
  def handle_event("filter_events", %{"timeline" => %{"query" => query}}, socket) do
    {:noreply, assign(socket, :event_query, query || "")}
  end

  def handle_event("filter_events", _params, socket) do
    {:noreply, assign(socket, :event_query, "")}
  end

  def handle_event("filter_tasks", %{"filter" => filter}, socket) when filter in ["all", "running", "retrying"] do
    {:noreply, assign(socket, :task_filter, filter)}
  end

  def handle_event("filter_tasks", _params, socket), do: {:noreply, socket}

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
  def handle_event("reply_to_ticket", %{"issue_id" => issue_id, "body" => body}, socket) do
    issue_id = normalize_reply_issue_id(issue_id)
    body = normalize_reply_body(body)

    cond do
      issue_id == "" ->
        {:noreply, put_ticket_reply_error(socket, issue_id, "Ticket id is required.")}

      body == "" ->
        {:noreply, put_ticket_reply_error(socket, issue_id, "Reply body is required.")}

      true ->
        case Tracker.create_comment(issue_id, body) do
          :ok ->
            {:noreply,
             socket
             |> assign(:payload, load_payload(socket.assigns.selected_issue_identifier))
             |> assign(:now, DateTime.utc_now())
             |> put_ticket_reply_notice(issue_id, "Reply sent")}

          {:error, reason} ->
            {:noreply, put_ticket_reply_error(socket, issue_id, "Could not send reply: #{format_tracker_error(reason)}")}
        end
    end
  end

  def handle_event("reply_to_ticket", _params, socket) do
    {:noreply, put_ticket_reply_error(socket, "", "Ticket id and reply body are required.")}
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
    <section class="dashboard-shell" aria-labelledby="dashboard-title">
      <header class="dashboard-header">
        <div class="dashboard-header-main">
          <div>
            <p class="eyebrow">Orchestrum Observability</p>
            <h1 id="dashboard-title" class="dashboard-title">
              Operations Dashboard
            </h1>
            <p class="dashboard-copy">
              Current state, queue pressure, token usage, and operational controls for this local runtime.
            </p>
          </div>

          <div class="toolbar" aria-label="Dashboard actions">
            <button
              type="button"
              class="toolbar-button"
              phx-click="refresh_now"
              phx-disable-with="Refreshing"
              data-confirm="Queue an immediate poll and reconciliation cycle?"
              aria-label="Refresh dashboard now"
              title="Refresh dashboard now"
            >
              <span class="button-icon" aria-hidden="true">
                <svg viewBox="0 0 20 20" focusable="false">
                  <path d="M16 6v4h-4" />
                  <path d="M4 14v-4h4" />
                  <path d="M14.6 7A5.5 5.5 0 0 0 5 8.2" />
                  <path d="M5.4 13A5.5 5.5 0 0 0 15 11.8" />
                </svg>
              </span>
              <span>Refresh</span>
            </button>
            <button
              type="button"
              class="subtle-button"
              phx-click="control"
              phx-value-action={global_polling_action(@payload)}
              data-confirm={global_polling_confirm(@payload)}
              phx-disable-with="Working"
              disabled={controls_disabled?(@payload)}
            >
              <%= global_polling_label(@payload) %>
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
              <span class="toolbar-notice" role="status"><%= @refresh_notice %></span>
            <% end %>
            <%= if @control_notice do %>
              <span class="muted"><%= @control_notice %></span>
            <% end %>
          </div>
        </div>
      </header>

      <nav class="section-nav" aria-label="Dashboard sections">
        <%= for item <- dashboard_views() do %>
          <.link
            patch={item.path}
            class={nav_link_class(item.id, @current_view)}
            aria-current={if item.id == @current_view, do: "page", else: nil}
            data-dashboard-view={item.id}
          >
            <span><%= item.label %></span>
            <%= if count = dashboard_nav_count(item.id, @payload, @selected_project_id) do %>
              <span class="nav-count numeric"><%= count %></span>
            <% end %>
          </.link>
        <% end %>
      </nav>

      <%= if @payload[:error] do %>
        <section id="diagnostics" class="ops-panel error-panel" aria-labelledby="diagnostics-title" role="alert">
          <h2 id="diagnostics-title" class="section-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <%= if @payload.selected_detail do %>
          <section id="run-detail" class="ops-panel run-detail-card" aria-labelledby="run-detail-title">
            <%= if @payload.selected_detail[:error] do %>
              <div class="section-header">
                <div>
                  <h2 id="run-detail-title" class="section-title">Run details</h2>
                  <p class="section-copy"><%= @payload.selected_detail.error.message %></p>
                </div>
                <a class="issue-link" href="/">Dashboard</a>
              </div>
            <% else %>
              <% detail = @payload.selected_detail %>
              <% timeline_events = filtered_timeline(detail.timeline, @event_query) %>

              <div class="section-header">
                <div>
                  <h2 id="run-detail-title" class="section-title"><%= detail.issue_identifier %> run details</h2>
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

        <section id="overview" class="ops-panel" aria-labelledby="overview-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Overview</p>
              <h2 id="overview-title" class="section-title">Runtime summary</h2>
            </div>
            <span class="timestamp-pill">Generated <%= format_generated_at(@payload.generated_at) %></span>
          </div>

          <div class="metric-grid">
            <article class="metric-card">
              <p class="metric-label">Running</p>
              <p class="metric-value numeric"><%= @payload.counts.running %></p>
              <p class="metric-detail">Active issue sessions.</p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Retry queue</p>
              <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
              <p class="metric-detail">Waiting for a retry window.</p>
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
              <p class="metric-detail">Completed plus active runtime.</p>
            </article>

            <article class="metric-card">
              <p class="metric-label">Next poll</p>
              <p class="metric-value numeric"><%= format_polling(@payload.polling) %></p>
              <p class="metric-detail">Poll interval <%= format_poll_interval(@payload.polling) %>.</p>
            </article>
          </div>
        </section>

        <section id="tasks" class="ops-panel" aria-labelledby="tasks-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Tasks</p>
              <h2 id="tasks-title" class="section-title">Task board</h2>
              <p class="section-copy">Active and retrying work, filtered without changing orchestrator state.</p>
            </div>

            <div class="segmented-control" role="group" aria-label="Filter task board">
              <button
                type="button"
                class={task_filter_button_class(@task_filter, "all")}
                phx-click="filter_tasks"
                phx-value-filter="all"
                aria-pressed={to_string(@task_filter == "all")}
              >
                All <span class="numeric"><%= visible_task_count(@payload, @selected_project_id) %></span>
              </button>
              <button
                type="button"
                class={task_filter_button_class(@task_filter, "running")}
                phx-click="filter_tasks"
                phx-value-filter="running"
                aria-pressed={to_string(@task_filter == "running")}
              >
                Running <span class="numeric"><%= visible_running_count(@payload, @selected_project_id) %></span>
              </button>
              <button
                type="button"
                class={task_filter_button_class(@task_filter, "retrying")}
                phx-click="filter_tasks"
                phx-value-filter="retrying"
                aria-pressed={to_string(@task_filter == "retrying")}
              >
                Retrying <span class="numeric"><%= visible_retrying_count(@payload, @selected_project_id) %></span>
              </button>
            </div>
          </div>

          <%= if task_filter_empty?(@payload, @task_filter, @selected_project_id) do %>
            <p class="empty-state">No <%= task_filter_empty_label(@task_filter) %> tasks.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table task-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Queue</th>
                    <th>Project</th>
                    <th>Status</th>
                    <th>Timing</th>
                    <th>Last signal</th>
                  </tr>
                </thead>
                <tbody>
                  <%= if @task_filter in ["all", "running"] do %>
                    <tr :for={entry <- visible_running(@payload, @selected_project_id)}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={entry.detail_path}>Details</a>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                        </div>
                      </td>
                      <td><span class="queue-label queue-label-running">Running</span></td>
                      <td><%= project_label(entry.project) %></td>
                      <td>
                        <span class={state_badge_class(entry.state)}>
                          <%= entry.state %>
                        </span>
                      </td>
                      <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                      <td>
                        <span class="event-text" title={entry.last_message || to_string(entry.last_event || "n/a")}>
                          <%= entry.last_message || to_string(entry.last_event || "n/a") %>
                        </span>
                      </td>
                    </tr>
                  <% end %>

                  <%= if @task_filter in ["all", "retrying"] do %>
                    <tr :for={entry <- visible_retrying(@payload, @selected_project_id)}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={entry.detail_path}>Details</a>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                        </div>
                      </td>
                      <td><span class="queue-label queue-label-retrying">Retrying</span></td>
                      <td><%= project_label(entry.project) %></td>
                      <td><span class="state-badge state-badge-warning">Attempt <%= entry.attempt %></span></td>
                      <td class="mono numeric"><%= entry.due_at || "n/a" %></td>
                      <td>
                        <span class="event-text" title={entry.error || "n/a"}><%= entry.error || "n/a" %></span>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section id="mcp-servers" class="ops-panel" aria-labelledby="mcp-servers-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Diagnostics</p>
              <h2 id="mcp-servers-title" class="section-title">MCP servers</h2>
              <p class="section-copy">Configured MCP servers reported by active Codex sessions.</p>
            </div>
          </div>

          <%= if @payload.mcp_servers == [] do %>
            <p class="empty-state">No MCP servers reported.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Server</th>
                    <th>Status</th>
                    <th>Issue</th>
                    <th>Detail</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={server <- @payload.mcp_servers}>
                    <td class="mono"><%= server.name %></td>
                    <td>
                      <span class={state_badge_class(server.status)}>
                        <%= server.status %>
                      </span>
                    </td>
                    <td>
                      <%= if server.issue_identifier do %>
                        <a class="issue-link" href={"/api/v1/#{server.issue_identifier}"}><%= server.issue_identifier %></a>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td><%= server.detail || "n/a" %></td>
                    <td>
                      <%= if server.action do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label={mcp_action_label(server.action)}
                          data-copy={mcp_action_copy(server)}
                          aria-label={"Copy #{mcp_action_label(server.action)} instructions for #{server.name}"}
                          title={"Copy #{mcp_action_label(server.action)} instructions for #{server.name}"}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          <%= mcp_action_label(server.action) %>
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section id="runs" class="ops-panel" aria-labelledby="runs-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Runs</p>
              <h2 id="runs-title" class="section-title">Running sessions</h2>
              <p class="section-copy">Live agent runs with workspace, event, and token context.</p>
            </div>
          </div>

          <%= if visible_running(@payload, @selected_project_id) == [] do %>
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
                  <col style="width: 16rem;" />
                  <col style="width: 8rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Project</th>
                    <th>State</th>
                    <th>Workspace</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                    <th>Reply</th>
                    <th>Controls</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- visible_running(@payload, @selected_project_id)}>
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
                      <div class="detail-stack">
                        <span class="mono path-text"><%= entry.workspace_path || "default workspace" %></span>
                        <span class="muted"><%= entry.worker_host || "local worker" %></span>
                      </div>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            aria-label={"Copy session ID for #{entry.issue_identifier}"}
                            title={"Copy session ID for #{entry.issue_identifier}"}
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
                            - <span class="mono numeric"><%= entry.last_event_at %></span>
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
                    <td class="ticket-reply-cell">
                      <%= if can_reply_to_ticket?(entry) do %>
                        <form id={"ticket-reply-form-#{entry.issue_id}"} class="ticket-reply-form" phx-submit="reply_to_ticket">
                          <input type="hidden" name="issue_id" value={entry.issue_id} />
                          <textarea name="body" rows="2" aria-label={"Reply to #{entry.issue_identifier}"} placeholder="Reply..."></textarea>
                          <button type="submit" class="subtle-button">Reply</button>
                          <%= if notice = ticket_reply_notice(@ticket_reply_notices, entry.issue_id) do %>
                            <p class="form-notice"><%= notice %></p>
                          <% end %>
                          <%= if error = ticket_reply_error(@ticket_reply_errors, entry.issue_id) do %>
                            <p class="form-error"><%= error %></p>
                          <% end %>
                        </form>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td>
                      <button
                        type="button"
                        class="subtle-button danger-button"
                        phx-click="control"
                        phx-value-action="cancel_run"
                        phx-value-target={entry.issue_identifier}
                        data-confirm={"Cancel active run for #{entry.issue_identifier}?"}
                        phx-disable-with="Canceling"
                        disabled={controls_disabled?(@payload)}
                      >
                        Stop
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section id="projects" class="ops-panel" aria-labelledby="projects-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Projects</p>
              <h2 id="projects-title" class="section-title">Project command center</h2>
              <p class="section-copy">Command center, health, and scoped controls.</p>
            </div>
            <div class="project-toolbar">
              <form phx-change="filter_project" class="project-filter">
                <label>
                  <span>Project</span>
                  <select name="project" aria-label="Filter project">
                    <option value="all" selected={@selected_project_id == "all"}>All projects</option>
                    <option :for={project <- @payload.projects} value={project.id} selected={@selected_project_id == project.id}>
                      <%= project.name || project.id %>
                    </option>
                  </select>
                </label>
              </form>
              <button
                type="button"
                class="icon-button"
                phx-click="show_project_form"
                aria-label="Add project"
                title="Add project"
              >
                <span aria-hidden="true">+</span>
              </button>
            </div>
          </div>

          <%= if @project_form_notice do %>
            <p class="form-notice" role="status"><%= @project_form_notice %></p>
          <% end %>
          <%= if @project_action_notice do %>
            <p class="form-notice" role="status"><%= @project_action_notice %></p>
          <% end %>
          <%= if @project_action_error do %>
            <p class="form-error" role="alert"><%= @project_action_error %></p>
          <% end %>

          <%= if @show_project_form do %>
            <form
              id="add-project-form"
              class="project-form"
              phx-submit="add_project"
              role="dialog"
              aria-label="Add project to workflow"
              data-confirm="Add this project to WORKFLOW.md?"
            >
              <div class="project-form-grid">
                <label>
                  <span>Project name</span>
                  <input name="project[name]" value={@project_form["name"] || ""} autocomplete="off" />
                </label>
                <label>
                  <span>Linear project slug</span>
                  <input name="project[project_slug]" value={@project_form["project_slug"] || ""} autocomplete="off" />
                </label>
                <label>
                  <span>Local directory</span>
                  <input name="project[workspace_root]" value={@project_form["workspace_root"] || ""} autocomplete="off" />
                </label>
                <label>
                  <span>Remote repository</span>
                  <input name="project[repository_path]" value={@project_form["repository_path"] || ""} autocomplete="off" />
                </label>
                <label>
                  <span>Git name</span>
                  <input name="project[git_name]" value={@project_form["git_name"] || ""} autocomplete="off" />
                </label>
                <label>
                  <span>Git username</span>
                  <input name="project[git_username]" value={@project_form["git_username"] || ""} autocomplete="off" />
                </label>
                <label>
                  <span>Git email</span>
                  <input name="project[git_email]" value={@project_form["git_email"] || ""} autocomplete="off" />
                </label>
              </div>
              <%= if @project_form_error do %>
                <p class="form-error" role="alert"><%= @project_form_error %></p>
              <% end %>
              <div class="form-actions">
                <button type="submit" phx-disable-with="Adding project">Add project</button>
                <button type="button" class="secondary" phx-click="cancel_project_form">Cancel</button>
              </div>
            </form>
          <% end %>

          <%= if visible_projects(@payload.projects, @selected_project_id) == [] do %>
            <p class="empty-state">No configured projects.</p>
          <% else %>
            <div class="project-command-grid">
              <article :for={project <- visible_projects(@payload.projects, @selected_project_id)} class="project-command-card">
                <div class="project-card-header">
                  <div>
                    <h3 class="project-title"><%= project.name || project.id %></h3>
                    <p class="project-subtitle mono"><%= project.tracker_kind %> / <%= project.tracker_project_slug || "n/a" %></p>
                  </div>
                  <span class={health_badge_class(project.health.status)}><%= project.health.status %></span>
                </div>

                <dl class="project-detail-grid">
                  <div>
                    <dt>Workspace root</dt>
                    <dd class="mono path-text"><%= project.workspace_root %></dd>
                  </div>
                  <div>
                    <dt>Repository</dt>
                    <dd class="mono path-text"><%= project.repository_path || "default hook" %></dd>
                  </div>
                  <div>
                    <dt>Active states</dt>
                    <dd><%= state_list(project.active_states) %></dd>
                  </div>
                  <div>
                    <dt>Terminal states</dt>
                    <dd><%= state_list(project.terminal_states) %></dd>
                  </div>
                  <div>
                    <dt>Git identity</dt>
                    <dd>
                      <div class="detail-stack">
                        <span :for={line <- git_identity_lines(project)} class="mono"><%= line %></span>
                      </div>
                    </dd>
                  </div>
                  <div>
                    <dt>Agent instructions</dt>
                    <dd><%= agent_instruction_status(project) %></dd>
                  </div>
                  <div>
                    <dt>Polling</dt>
                    <dd><%= project.polling.status %> · next <%= format_polling(project.polling) %></dd>
                  </div>
                  <div>
                    <dt>Last poll</dt>
                    <dd><%= poll_result_label(project.polling.last_result) %></dd>
                  </div>
                  <div>
                    <dt>Queue</dt>
                    <dd class="numeric">
                      <%= project.queue_counts.total %> total · <%= project.queue_counts.active_runs %> active · <%= project.queue_counts.retrying %> retrying
                    </dd>
                  </div>
                  <div>
                    <dt>Retry pressure</dt>
                    <dd><%= project.retry_pressure.level %> · max attempt <%= project.retry_pressure.max_attempt %></dd>
                  </div>
                </dl>

                <%= if project.health.problems != [] do %>
                  <ul class="project-problem-list">
                    <li :for={problem <- project.health.problems}>
                      <strong><%= problem.code %></strong>: <%= problem.message %>
                    </li>
                  </ul>
                <% end %>

                <div class="project-failure-block">
                  <p class="project-block-label">Recent failures</p>
                  <%= if project.recent_failures == [] do %>
                    <p class="muted">None</p>
                  <% else %>
                    <ul class="project-problem-list">
                      <li :for={failure <- project.recent_failures}>
                        <span class="issue-id"><%= failure.issue_identifier %></span>
                        attempt <%= failure.attempt %>: <%= failure.error %>
                      </li>
                    </ul>
                  <% end %>
                </div>

                <div class="project-card-actions">
                  <button type="button" class="subtle-button" phx-click="refresh_project" phx-value-project-id={project.id}>
                    Refresh
                  </button>
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="control"
                    phx-value-action={project_polling_action(@payload, project)}
                    phx-value-target={project_control_target(project)}
                    data-confirm={project_polling_confirm(@payload, project)}
                    phx-disable-with="Working"
                    disabled={controls_disabled?(@payload)}
                  >
                    <%= project_polling_label(@payload, project) %>
                  </button>
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="control"
                    phx-value-action="dispatch_project_now"
                    phx-value-target={project_control_target(project)}
                    data-confirm={"Dispatch #{project.name || project.id} now?"}
                    phx-disable-with="Queued"
                    disabled={controls_disabled?(@payload) or global_polling_paused?(@payload) or project_paused?(@payload, project)}
                  >
                    Dispatch now
                  </button>
                  <a href={dashboard_section_path(project.id, "tasks")} class="subtle-link">Tasks</a>
                  <a href={dashboard_section_path(project.id, "runs")} class="subtle-link">Runs</a>
                  <a href={dashboard_section_path(project.id, "settings")} class="subtle-link">Settings</a>
                  <a href={dashboard_section_path(project.id, "diagnostics")} class="subtle-link">Diagnostics</a>
                </div>
              </article>
            </div>
          <% end %>
        </section>

        <section id="retry-controls" class="ops-panel" aria-labelledby="retry-controls-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Retries</p>
              <h2 id="retry-controls-title" class="section-title">Retry queue controls</h2>
              <p class="section-copy">Backoff entries that can be retried now or cleared.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 720px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Project</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                    <th>Controls</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= project_label(entry.project) %></td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                    <td>
                      <div class="control-row">
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="control"
                          phx-value-action="retry_now"
                          phx-value-target={entry.issue_identifier}
                          data-confirm={"Retry #{entry.issue_identifier} now?"}
                          phx-disable-with="Queued"
                          disabled={controls_disabled?(@payload) or global_polling_paused?(@payload)}
                        >
                          Retry now
                        </button>
                        <button
                          type="button"
                          class="subtle-button danger-button"
                          phx-click="control"
                          phx-value-action="clear_retry"
                          phx-value-target={entry.issue_identifier}
                          data-confirm={"Clear retry entry for #{entry.issue_identifier}?"}
                          phx-disable-with="Clearing"
                          disabled={controls_disabled?(@payload)}
                        >
                          Clear
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <%= if @payload.claimed != [] do %>
          <section id="claimed-controls" class="ops-panel" aria-labelledby="claimed-controls-title">
            <div class="section-header">
              <div>
                <p class="section-kicker">Claims</p>
                <h2 id="claimed-controls-title" class="section-title">Claimed issues</h2>
                <p class="section-copy">Claims with no active run or retry entry.</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 420px;">
                <thead>
                  <tr>
                    <th>Issue ID</th>
                    <th>Controls</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.claimed}>
                    <td class="mono"><%= entry.issue_id %></td>
                    <td>
                      <button
                        type="button"
                        class="subtle-button danger-button"
                        phx-click="control"
                        phx-value-action="release_claim"
                        phx-value-target={entry.issue_id}
                        data-confirm={"Release claim for #{entry.issue_id}?"}
                        phx-disable-with="Releasing"
                        disabled={controls_disabled?(@payload)}
                      >
                        Release
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <section id="controls" class="ops-panel" aria-labelledby="controls-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Controls</p>
              <h2 id="controls-title" class="section-title">Operator controls</h2>
              <p class="section-copy">Manual actions that change runtime or workflow state.</p>
            </div>
          </div>

          <div class="control-grid">
            <div class="control-row">
              <div>
                <h3 class="control-title">Queue refresh</h3>
                <p class="control-copy">Poll Linear and reconcile current running state.</p>
              </div>
              <button
                type="button"
                class="toolbar-button"
                phx-click="refresh_now"
                phx-disable-with="Refreshing"
                data-confirm="Queue an immediate poll and reconciliation cycle?"
                aria-label="Queue manual refresh"
                title="Queue manual refresh"
              >
                <span class="button-icon" aria-hidden="true">
                  <svg viewBox="0 0 20 20" focusable="false">
                    <path d="M16 6v4h-4" />
                    <path d="M4 14v-4h4" />
                    <path d="M14.6 7A5.5 5.5 0 0 0 5 8.2" />
                    <path d="M5.4 13A5.5 5.5 0 0 0 15 11.8" />
                  </svg>
                </span>
                <span>Refresh</span>
              </button>
            </div>

            <div class="control-row">
              <div>
                <h3 class="control-title">Add project</h3>
                <p class="control-copy">Open the workflow-backed project form.</p>
              </div>
              <button
                type="button"
                class="toolbar-button secondary"
                phx-click="show_project_form"
                aria-label="Open add project form"
                title="Open add project form"
              >
                <span class="button-icon" aria-hidden="true">+</span>
                <span>Add project</span>
              </button>
            </div>
          </div>
        </section>

        <section id="settings" class="ops-panel" aria-labelledby="settings-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Settings</p>
              <h2 id="settings-title" class="section-title">Runtime settings</h2>
              <p class="section-copy">Read-only workflow values that shape dashboard behavior.</p>
            </div>
          </div>

          <div class="settings-grid">
            <div :for={setting <- settings_rows(@payload)} class="setting-row">
              <span class="setting-label"><%= setting.label %></span>
              <span class="setting-value"><%= setting.value %></span>
            </div>
          </div>
        </section>

        <section id="diagnostics" class="ops-panel" aria-labelledby="diagnostics-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Diagnostics</p>
              <h2 id="diagnostics-title" class="section-title">Diagnostics</h2>
              <p class="section-copy">Raw values and API entry points for debugging the current runtime.</p>
            </div>
            <div class="link-group" aria-label="Diagnostic API links">
              <a href="/api/v1/state">State JSON</a>
              <a href="/api/v1/refresh">Refresh endpoint</a>
            </div>
          </div>

          <div class="diagnostics-grid">
            <div>
              <h3 class="control-title">Rate limits</h3>
              <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
            </div>
            <div>
              <h3 class="control-title">Polling</h3>
              <pre class="code-panel"><%= pretty_value(@payload.polling) %></pre>
            </div>
          </div>
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

  defp selected_project_id(params, %{projects: projects}) when is_map(params) and is_list(projects) do
    case Map.get(params, "project") do
      project_id when project_id in [nil, "", "all"] ->
        "all"

      project_id ->
        case find_project(projects, project_id) do
          nil -> "all"
          project -> project.id
        end
    end
  end

  defp selected_project_id(_params, _payload), do: "all"

  defp dashboard_views, do: @dashboard_views

  defp view_from_params(%{"view" => view}, _action) when view in @view_ids, do: view
  defp view_from_params(_params, action), do: view_from_action(action)

  defp view_from_action(:show), do: "runs"

  defp view_from_action(action)
       when action in [:overview, :tasks, :runs, :projects, :controls, :settings, :diagnostics],
       do: Atom.to_string(action)

  defp view_from_action(_action), do: "overview"

  defp nav_link_class(view, view), do: "section-nav-link section-nav-link-active"
  defp nav_link_class(_view, _current_view), do: "section-nav-link"

  defp dashboard_nav_count(view, payload, project_id) when view in ["overview", "tasks"],
    do: visible_task_count(payload, project_id)

  defp dashboard_nav_count("runs", payload, project_id), do: visible_running_count(payload, project_id)
  defp dashboard_nav_count("projects", payload, project_id), do: visible_project_count(payload, project_id)
  defp dashboard_nav_count(_view, _payload, _project_id), do: nil

  defp visible_projects(projects, "all") when is_list(projects), do: projects

  defp visible_projects(projects, project_id) when is_list(projects) do
    projects
    |> Enum.filter(&(find_project([&1], project_id) != nil))
  end

  defp visible_projects(_projects, _project_id), do: []

  defp visible_running(%{running: running}, "all") when is_list(running), do: running

  defp visible_running(%{running: running, projects: projects}, project_id) when is_list(running) and is_list(projects) do
    visible_entries(running, projects, project_id)
  end

  defp visible_running(_payload, _project_id), do: []

  defp visible_retrying(%{retrying: retrying}, "all") when is_list(retrying), do: retrying

  defp visible_retrying(%{retrying: retrying, projects: projects}, project_id) when is_list(retrying) and is_list(projects) do
    visible_entries(retrying, projects, project_id)
  end

  defp visible_retrying(_payload, _project_id), do: []

  defp visible_entries(entries, projects, project_id) when is_list(entries) and is_list(projects) do
    case find_project(projects, project_id) do
      nil -> entries
      project -> Enum.filter(entries, &entry_for_project?(&1, project, projects))
    end
  end

  defp visible_entries(_entries, _projects, _project_id), do: []

  defp entry_for_project?(%{project: nil}, project, [single_project]) do
    normalize_key(project.id) == normalize_key(single_project.id)
  end

  defp entry_for_project?(%{project: entry_project}, project, _projects) when is_map(entry_project) do
    entry_keys = entry_project_keys(entry_project)
    project_keys = project_keys(project)
    Enum.any?(entry_keys, &(&1 in project_keys))
  end

  defp entry_for_project?(_entry, _project, _projects), do: false

  defp find_project(projects, project_id) when is_list(projects) do
    normalized_project_id = normalize_key(project_id)

    Enum.find(projects, fn project ->
      normalized_project_id in project_keys(project)
    end)
  end

  defp project_keys(project) when is_map(project) do
    [project[:id], project["id"], project[:name], project["name"], project[:tracker_project_slug], project["tracker_project_slug"]]
    |> Enum.map(&normalize_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp entry_project_keys(project) when is_map(project) do
    [project[:id], project["id"], project[:name], project["name"], project[:slug], project["slug"]]
    |> Enum.map(&normalize_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_key(_value), do: nil

  defp project_filter_path(project_id), do: dashboard_project_path("/", project_id)

  defp dashboard_section_path(project_id, section), do: dashboard_project_path(dashboard_view_path(section), project_id)

  defp dashboard_project_path(path, project_id) when project_id in [nil, "", "all"], do: path
  defp dashboard_project_path(path, project_id), do: path <> "?" <> URI.encode_query(%{"project" => project_id})

  defp dashboard_view_path("overview"), do: "/"
  defp dashboard_view_path(section) when section in @view_ids, do: "/" <> section
  defp dashboard_view_path(_section), do: "/"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || Config.snapshot_timeout_ms()
  end

  defp visible_task_count(payload, project_id),
    do: visible_running_count(payload, project_id) + visible_retrying_count(payload, project_id)

  defp visible_running_count(payload, project_id), do: payload |> visible_running(project_id) |> length()
  defp visible_retrying_count(payload, project_id), do: payload |> visible_retrying(project_id) |> length()

  defp visible_project_count(%{projects: projects}, project_id), do: projects |> visible_projects(project_id) |> length()
  defp visible_project_count(_payload, _project_id), do: 0

  defp task_filter_button_class(current, target) do
    if current == target do
      "segmented-button segmented-button-active"
    else
      "segmented-button"
    end
  end

  defp task_filter_empty?(payload, "running", project_id), do: visible_running_count(payload, project_id) == 0
  defp task_filter_empty?(payload, "retrying", project_id), do: visible_retrying_count(payload, project_id) == 0
  defp task_filter_empty?(payload, _filter, project_id), do: visible_task_count(payload, project_id) == 0

  defp task_filter_empty_label("running"), do: "running"
  defp task_filter_empty_label("retrying"), do: "retrying"
  defp task_filter_empty_label(_filter), do: "active or retrying"

  defp settings_rows(payload) do
    settings = Config.settings!()

    [
      %{label: "Tracker", value: settings.tracker.kind || "n/a"},
      %{label: "Project slug", value: settings.tracker.project_slug || "n/a"},
      %{label: "Active states", value: Enum.join(settings.tracker.active_states || [], ", ")},
      %{label: "Terminal states", value: Enum.join(settings.tracker.terminal_states || [], ", ")},
      %{label: "Polling interval", value: format_poll_interval(payload.polling)},
      %{label: "Snapshot timeout", value: "#{settings.observability.snapshot_timeout_ms} ms"},
      %{label: "Workspace root", value: settings.workspace.root},
      %{label: "Agent capacity", value: Integer.to_string(settings.agent.max_concurrent_agents)},
      %{label: "Max turns", value: Integer.to_string(settings.agent.max_turns)},
      %{label: "Server", value: server_setting(settings.server)}
    ]
  end

  defp server_setting(%{enabled: false}), do: "disabled"
  defp server_setting(%{host: host, port: nil}), do: "#{host}:4000"
  defp server_setting(%{host: host, port: port}), do: "#{host}:#{port}"

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

  defp format_generated_at(generated_at) when is_binary(generated_at), do: generated_at
  defp format_generated_at(_generated_at), do: "n/a"

  defp project_label(nil), do: "n/a"
  defp project_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp project_label(%{id: id}) when is_binary(id) and id != "", do: id
  defp project_label(project) when is_map(project), do: project[:slug] || "n/a"
  defp project_label(_project), do: "n/a"

  defp state_list(states) when is_list(states), do: Enum.join(states, ", ")
  defp state_list(_states), do: "n/a"

  defp poll_result_label(%{status: status, message: message}) when is_binary(status) and is_binary(message) do
    "#{status}: #{message}"
  end

  defp poll_result_label(_result), do: "n/a"

  defp health_badge_class("healthy"), do: "state-badge state-badge-active"
  defp health_badge_class("error"), do: "state-badge state-badge-danger"
  defp health_badge_class(_status), do: "state-badge state-badge-warning"

  defp mcp_action_label("re_auth"), do: "Re-auth"
  defp mcp_action_label("re_config"), do: "Re-config"
  defp mcp_action_label(_action), do: "Review"

  defp mcp_action_copy(%{action: "re_auth", name: name}) do
    "Re-auth MCP server #{name} in the Codex MCP configuration, then retry the affected session."
  end

  defp mcp_action_copy(%{action: "re_config", name: name}) do
    "Review MCP server #{name} in the Codex MCP configuration, then retry the affected session."
  end

  defp mcp_action_copy(%{name: name}) do
    "Review MCP server #{name} in the Codex MCP configuration."
  end

  defp default_project_form do
    %{
      "name" => "",
      "project_slug" => "",
      "workspace_root" => "",
      "repository_path" => "",
      "git_name" => "",
      "git_username" => "",
      "git_email" => ""
    }
  end

  defp project_form(params) when is_map(params) do
    %{
      "name" => params["name"] || "",
      "project_slug" => params["project_slug"] || params["tracker_project_slug"] || "",
      "workspace_root" => project_form_value(params, "workspace_root", ["workspace", "root"]),
      "repository_path" => project_form_value(params, "repository_path", ["repository", "path"]),
      "git_name" => project_form_value(params, "git_name", ["git", "name"]),
      "git_username" => project_form_value(params, "git_username", ["git", "username"]),
      "git_email" => project_form_value(params, "git_email", ["git", "email"])
    }
  end

  defp project_form_value(params, flat_key, [parent_key, child_key]) do
    params[flat_key] || get_in(params, [parent_key, child_key]) || ""
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

  defp git_identity_lines(project) do
    [
      git_identity_line("name", Map.get(project, :git_name)),
      git_identity_line("username", Map.get(project, :git_username)),
      git_identity_line("email", Map.get(project, :git_email))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["not set"]
      lines -> lines
    end
  end

  defp git_identity_line(_label, nil), do: nil
  defp git_identity_line(_label, ""), do: nil
  defp git_identity_line(label, value), do: "#{label}: #{value}"

  defp agent_instruction_status(%{agent_instruction_file: filename}) when is_binary(filename) and filename != "" do
    "#{filename} found"
  end

  defp agent_instruction_status(_project), do: "checked in prepared workspace"

  defp put_ticket_reply_notice(socket, issue_id, message) do
    issue_id = normalize_reply_issue_id(issue_id)

    socket
    |> assign(:ticket_reply_notices, Map.put(socket.assigns.ticket_reply_notices, issue_id, message))
    |> assign(:ticket_reply_errors, Map.delete(socket.assigns.ticket_reply_errors, issue_id))
  end

  defp put_ticket_reply_error(socket, issue_id, message) do
    issue_id = normalize_reply_issue_id(issue_id)

    socket
    |> assign(:ticket_reply_errors, Map.put(socket.assigns.ticket_reply_errors, issue_id, message))
    |> assign(:ticket_reply_notices, Map.delete(socket.assigns.ticket_reply_notices, issue_id))
  end

  defp ticket_reply_notice(notices, issue_id), do: Map.get(notices, normalize_reply_issue_id(issue_id))
  defp ticket_reply_error(errors, issue_id), do: Map.get(errors, normalize_reply_issue_id(issue_id))

  defp normalize_reply_issue_id(nil), do: ""
  defp normalize_reply_issue_id(issue_id), do: issue_id |> to_string() |> String.trim()

  defp normalize_reply_body(nil), do: ""
  defp normalize_reply_body(body), do: body |> to_string() |> String.trim()

  defp can_reply_to_ticket?(%{issue_id: issue_id, state: state}) when is_binary(issue_id) do
    String.trim(issue_id) != "" and human_review_state?(state)
  end

  defp can_reply_to_ticket?(_entry), do: false

  defp human_review_state?(state) do
    normalized =
      state
      |> to_string()
      |> String.trim()
      |> String.downcase()

    normalized in ["human review", "need human review", "needs human review"] or
      (String.contains?(normalized, "human") and String.contains?(normalized, "review"))
  end

  defp format_tracker_error({:unsupported_tracker_write, kind}), do: "tracker comments are unavailable for #{kind}"
  defp format_tracker_error(reason), do: inspect(reason)

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

  defp control_notice(%{ok: false, message: message, result_id: result_id}) do
    "#{message} (#{result_id})"
  end

  defp control_notice(%{message: message, result_id: result_id}) do
    "#{message} (#{result_id})"
  end

  defp control_notice(%{"ok" => false, "message" => message, "result_id" => result_id}) do
    "#{message} (#{result_id})"
  end

  defp control_notice(%{"message" => message, "result_id" => result_id}) do
    "#{message} (#{result_id})"
  end

  defp control_notice(_payload), do: "Control request finished"

  defp controls_disabled?(%{error: _error}), do: true
  defp controls_disabled?(_payload), do: false

  defp global_polling_paused?(payload) do
    payload
    |> controls()
    |> Map.get(:polling_paused, false)
  end

  defp global_polling_action(payload) do
    if global_polling_paused?(payload), do: "resume_global", else: "pause_global"
  end

  defp global_polling_label(payload) do
    if global_polling_paused?(payload), do: "Resume polling", else: "Pause polling"
  end

  defp global_polling_confirm(payload) do
    if global_polling_paused?(payload), do: "Resume global polling?", else: "Pause global polling?"
  end

  defp project_paused?(payload, project) do
    paused_projects =
      payload
      |> controls()
      |> Map.get(:paused_projects, [])

    project_control_target(project) in paused_projects
  end

  defp project_polling_action(payload, project) do
    if project_paused?(payload, project), do: "resume_project", else: "pause_project"
  end

  defp project_polling_label(payload, project) do
    if project_paused?(payload, project), do: "Resume", else: "Pause"
  end

  defp project_polling_confirm(payload, project) do
    project_name = project.name || project.id

    if project_paused?(payload, project) do
      "Resume polling for #{project_name}?"
    else
      "Pause polling for #{project_name}?"
    end
  end

  defp project_control_target(%{id: id}) when is_binary(id) and id != "", do: id
  defp project_control_target(%{tracker_project_slug: slug}) when is_binary(slug) and slug != "", do: slug
  defp project_control_target(%{name: name}) when is_binary(name) and name != "", do: name
  defp project_control_target(_project), do: "default"

  defp controls(%{controls: controls}) when is_map(controls), do: controls
  defp controls(_payload), do: %{polling_paused: false, paused_projects: []}

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
