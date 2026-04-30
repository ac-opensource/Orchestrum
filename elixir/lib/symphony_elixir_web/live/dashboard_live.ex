defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Orchestrum.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, ProjectRegistry, Tracker}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @dashboard_views [
    %{id: "overview", label: "Command Center", path: "/", icon: "dashboard"},
    %{id: "tasks", label: "Task Manager", path: "/tasks", icon: "account_tree"},
    %{id: "runs", label: "Run Monitor", path: "/runs", icon: "timeline"},
    %{id: "projects", label: "Agent Config", path: "/projects", icon: "smart_toy"},
    %{id: "controls", label: "Workflow Builder", path: "/controls", icon: "hub"},
    %{id: "settings", label: "System Settings", path: "/settings", icon: "settings"},
    %{id: "diagnostics", label: "Audit Logs", path: "/diagnostics", icon: "terminal"}
  ]
  @view_ids Enum.map(@dashboard_views, & &1.id)

  @impl true
  def mount(params, _session, socket) do
    task_board_filters = Presenter.normalize_task_board_filters(params)
    selected_issue_identifier = params["issue_identifier"]
    selected_task_issue_identifier = selected_task_issue_identifier(params)
    payload = load_payload(task_board_filters, selected_issue_identifier)

    socket =
      socket
      |> assign(:selected_issue_identifier, selected_issue_identifier)
      |> assign(:event_query, "")
      |> assign(:payload, payload)
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
      |> assign(:settings_project_id, nil)
      |> assign(:task_board_filters, task_board_filters)
      |> assign(:selected_task_issue_identifier, selected_task_issue_identifier)
      |> assign(:selected_task_issue, select_task_issue(payload, selected_task_issue_identifier))
      |> assign(:ticket_reply_errors, %{})
      |> assign(:ticket_reply_notices, %{})
      |> assign(:workflow_selected_node_id, "content-research")
      |> assign(:workflow_notice, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    task_board_filters = Presenter.normalize_task_board_filters(params)
    selected_issue_identifier = params["issue_identifier"]
    selected_task_issue_identifier = selected_task_issue_identifier(params)

    {:noreply,
     socket
     |> assign(:selected_issue_identifier, selected_issue_identifier)
     |> assign(:current_view, view_from_params(params, socket.assigns.live_action))
     |> assign(:selected_project_id, selected_project_id(params, socket.assigns.payload))
     |> assign(:task_board_filters, task_board_filters)
     |> assign(:selected_task_issue_identifier, selected_task_issue_identifier)
     |> assign_payload()}
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
     |> assign_payload()
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
     |> assign_payload()
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
     |> assign_payload()
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
     |> assign_payload()
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
  def handle_event("select_workflow_node", %{"node-id" => node_id}, socket) do
    selected_node = workflow_node(node_id) || default_workflow_node()

    {:noreply,
     socket
     |> assign(:workflow_selected_node_id, selected_node.id)
     |> assign(:workflow_notice, "#{selected_node.label} selected in mock builder.")}
  end

  @impl true
  def handle_event("preview_workflow_node", _params, socket) do
    selected_node = workflow_node(socket.assigns.workflow_selected_node_id) || default_workflow_node()

    {:noreply,
     assign(
       socket,
       :workflow_notice,
       "Mock preview for #{selected_node.label}: #{selected_node.preview}"
     )}
  end

  @impl true
  def handle_event("mock_deploy_workflow", _params, socket) do
    {:noreply,
     assign(
       socket,
       :workflow_notice,
       "Mock deploy staged #{length(workflow_canvas_nodes())} nodes locally. No tracker or orchestrator state changed."
     )}
  end

  @impl true
  def handle_event("filter_task_board", %{"task_board" => raw_filters}, socket) do
    filters = Presenter.normalize_task_board_filters(raw_filters)
    {:noreply, push_patch(socket, to: task_board_path(filters, socket.assigns.selected_task_issue_identifier))}
  end

  def handle_event("filter_task_board", _params, socket) do
    {:noreply, push_patch(socket, to: task_board_path(%{}, socket.assigns.selected_task_issue_identifier))}
  end

  def handle_event("filter_task_search", %{"query" => query}, socket) do
    filters =
      socket.assigns.task_board_filters
      |> Map.put(:query, query || "")
      |> Presenter.normalize_task_board_filters()

    {:noreply, push_patch(socket, to: task_board_path(filters, socket.assigns.selected_task_issue_identifier))}
  end

  def handle_event("filter_task_search", _params, socket) do
    filters = socket.assigns.task_board_filters
    selected_identifier = socket.assigns.selected_task_issue_identifier

    {:noreply, push_patch(socket, to: task_board_path(filters, selected_identifier))}
  end

  @impl true
  def handle_event("select_task_issue", %{"identifier" => identifier}, socket) do
    {:noreply, push_patch(socket, to: task_board_path(socket.assigns.task_board_filters, identifier))}
  end

  @impl true
  def handle_event("clear_task_issue", _params, socket) do
    {:noreply, push_patch(socket, to: task_board_path(socket.assigns.task_board_filters, nil))}
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
  def handle_event("change_project_form", %{"project" => project_params}, socket) do
    {:noreply,
     socket
     |> assign(:show_project_form, true)
     |> assign(:project_form, project_form(project_params))
     |> assign(:project_form_error, nil)
     |> assign(:project_form_notice, nil)}
  end

  def handle_event("change_project_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_project_form, true)
     |> assign(:project_form, default_project_form())
     |> assign(:project_form_error, nil)
     |> assign(:project_form_notice, nil)}
  end

  @impl true
  def handle_event("cycle_settings_project", %{"direction" => direction}, socket) do
    projects = Map.get(socket.assigns.payload, :projects, [])

    current_project =
      selected_settings_project(
        socket.assigns.payload,
        socket.assigns.settings_project_id,
        socket.assigns.selected_project_id
      )

    {:noreply, assign(socket, :settings_project_id, cycled_settings_project_id(projects, current_project, direction))}
  end

  def handle_event("cycle_settings_project", _params, socket), do: {:noreply, socket}

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
             |> assign_payload()
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
         |> assign_payload()
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
    <section
      class={["dashboard-shell", "dashboard-view-#{@current_view}"]}
      aria-labelledby="dashboard-title"
      data-current-view={@current_view}
    >
      <aside class="command-rail" aria-label="Orchestrum command navigation">
        <div class="brand-lockup">
          <p class="brand-title">AION-OS</p>
          <p class="brand-subtitle">Orchestrum Runtime</p>
        </div>

        <nav class="section-nav" aria-label="Dashboard sections">
          <%= for item <- dashboard_primary_views() do %>
            <.link
              patch={dashboard_project_path(item.path, @selected_project_id)}
              class={nav_link_class(item.id, @current_view)}
              aria-current={if item.id == @current_view, do: "page", else: nil}
              data-dashboard-view={item.id}
            >
              <span class="nav-icon material-symbols-outlined" aria-hidden="true"><%= item.icon %></span>
              <span><%= item.label %></span>
              <%= if count = dashboard_nav_count(item.id, @payload, @selected_project_id) do %>
                <span class="nav-count numeric"><%= count %></span>
              <% end %>
            </.link>
          <% end %>
        </nav>

        <.link patch={dashboard_project_path(dashboard_view_path("controls"), @selected_project_id)} class="rail-deploy-link">
          <span class="material-symbols-outlined" aria-hidden="true">add_circle</span>
          <span>New Deployment</span>
        </.link>

        <div class="rail-footer" aria-label="Support links">
          <.link
            patch={dashboard_project_path(dashboard_view_path("settings"), @selected_project_id)}
            data-dashboard-view="settings"
            aria-current={if @current_view == "settings", do: "page", else: nil}
          >
            <span class="material-symbols-outlined" aria-hidden="true">settings</span>
            System Settings
          </.link>
          <a href="/api/v1/state">State API</a>
        </div>
      </aside>

      <header class="dashboard-header">
        <div class="dashboard-header-main">
          <div class="dashboard-heading">
            <p class="eyebrow">System Monitor</p>
            <h1 id="dashboard-title" class="dashboard-title">
              Operations Command Center
            </h1>
          </div>

          <form id="dashboard-search" class="dashboard-search" role="search" phx-change="filter_task_search">
            <span class="material-symbols-outlined" aria-hidden="true">search</span>
            <input
              type="search"
              name="query"
              value={task_board_query(@payload)}
              placeholder="Search operational logs..."
              aria-label="Search operational logs"
              phx-debounce="300"
              autocomplete="off"
            />
          </form>

          <div class="toolbar" aria-label="Dashboard actions">
            <button type="button" class="icon-button header-icon" aria-label="Notifications" title="Notifications">
              <span class="material-symbols-outlined" aria-hidden="true">notifications</span>
            </button>
            <button type="button" class="icon-button header-icon" aria-label="Sensors" title="Sensors">
              <span class="material-symbols-outlined" aria-hidden="true">sensors</span>
            </button>
            <.link patch={dashboard_project_path(dashboard_view_path("controls"), @selected_project_id)} class="deploy-button">
              <span>Deploy Agent</span>
            </.link>
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
              class="subtle-button header-control"
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
            <button type="button" class="icon-button header-icon" aria-label="Account" title="Account">
              <span class="material-symbols-outlined" aria-hidden="true">account_circle</span>
            </button>
          </div>
        </div>
      </header>

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

        <section :if={@current_view == "overview"} id="overview" class="ops-panel" aria-labelledby="overview-title">
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

        <section :if={@current_view == "tasks"} id="tasks" class="ops-panel task-board-section" aria-labelledby="tasks-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Tasks</p>
              <h2 id="tasks-title" class="section-title">Task board</h2>
              <p class="section-copy">Tracker-backed queue for configured projects.</p>
            </div>
            <span class="timestamp-pill numeric">
              <%= @payload.task_board.filtered_count %> / <%= @payload.task_board.total_count %>
            </span>
          </div>

          <%= if @payload.task_board.error do %>
            <p class="form-error"><%= @payload.task_board.error.message %></p>
          <% end %>

          <form id="task-board-filters" class="task-filter-form" phx-change="filter_task_board">
            <div class="task-filter-fields">
              <label>
                <span>Project</span>
                <select name="task_board[project]">
                  <option value="" selected={@payload.task_board.filters.project == ""}>All projects</option>
                  <option
                    :for={option <- @payload.task_board.options.projects}
                    value={option.value}
                    selected={@payload.task_board.filters.project == option.value}
                  ><%= option.label %></option>
                </select>
              </label>

              <label>
                <span>State</span>
                <select name="task_board[state]">
                  <option value="" selected={@payload.task_board.filters.state == ""}>All states</option>
                  <option
                    :for={option <- @payload.task_board.options.states}
                    value={option.value}
                    selected={@payload.task_board.filters.state == option.value}
                  ><%= option.label %></option>
                </select>
              </label>

              <label>
                <span>Label</span>
                <select name="task_board[label]">
                  <option value="" selected={@payload.task_board.filters.label == ""}>All labels</option>
                  <option
                    :for={option <- @payload.task_board.options.labels}
                    value={option.value}
                    selected={@payload.task_board.filters.label == option.value}
                  ><%= option.label %></option>
                </select>
              </label>

              <label>
                <span>Status</span>
                <select name="task_board[status]">
                  <option
                    :for={option <- @payload.task_board.options.statuses}
                    value={option.value}
                    selected={@payload.task_board.filters.status == option.value}
                  ><%= option.label %></option>
                </select>
              </label>

              <label class="task-filter-query">
                <span>Search</span>
                <input
                  type="search"
                  name="task_board[query]"
                  value={@payload.task_board.filters.query}
                  phx-debounce="300"
                  autocomplete="off"
                />
              </label>
            </div>

            <div class="task-filter-summary">
              <span class="mono">ACTIVE TASKS: <strong><%= @payload.task_board.filtered_count %></strong></span>
              <span class="task-filter-action">
                <span class="material-symbols-outlined" aria-hidden="true">filter_list</span>
                Filters
              </span>
            </div>
          </form>

          <div class="task-board-layout">
            <div class="task-table-panel">
              <table class="task-board-table">
                <thead>
                  <tr>
                    <th>Task ID</th>
                    <th>Agent</th>
                    <th>Status</th>
                    <th>Project</th>
                    <th>Signal</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for group <- @payload.task_board.groups do %>
                    <tr class="task-group-divider">
                      <th colspan="5">
                        <span><%= group.title %></span>
                        <span class="numeric"><%= group.count %></span>
                      </th>
                    </tr>

                    <%= if group.issues == [] do %>
                      <tr class="task-board-table-row">
                        <td colspan="5"><p class="empty-state">No issues.</p></td>
                      </tr>
                    <% else %>
                      <tr
                        :for={issue <- group.issues}
                        class={[
                          "task-board-table-row",
                          selected_task_issue?(@selected_task_issue_identifier, issue) && "task-issue-row-selected"
                        ]}
                      >
                        <td>
                          <button
                            type="button"
                            class="task-issue-button"
                            phx-click="select_task_issue"
                            phx-value-identifier={issue.issue_identifier}
                          >
                            <span class="issue-id"><%= issue.issue_identifier %></span>
                            <span class="task-selected-chip" :if={selected_task_issue?(@selected_task_issue_identifier, issue)}>Selected</span>
                          </button>
                        </td>
                        <td>
                          <div class="task-agent-stack">
                            <span><%= issue.title %></span>
                            <span><%= assignee_label(issue.assignee) %> · Age <%= issue.age_label %></span>
                          </div>
                        </td>
                        <td>
                          <span class={state_badge_class(issue.state)}>
                            <%= issue.state %>
                          </span>
                        </td>
                        <td>
                          <div class="task-agent-stack">
                            <span><%= issue.project_label %></span>
                            <span>Updated <%= issue.updated_label %></span>
                          </div>
                        </td>
                        <td>
                          <div class="task-signal-stack">
                            <span class={run_status_class(issue.run_status.status)}>
                              <%= issue.run_status.label %>
                            </span>
                            <span><%= issue.relations.label %></span>
                            <span class="task-labels">
                              <span :for={label <- issue.labels} class="task-label"><%= label %></span>
                              <span :if={issue.labels == []} class="muted">No labels</span>
                            </span>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
            </div>

            <aside class="task-detail-panel">
              <%= if @selected_task_issue do %>
                <div class="task-detail-header">
                  <div>
                    <p class="eyebrow"><%= @selected_task_issue.issue_identifier %></p>
                    <h3><%= @selected_task_issue.title %></h3>
                    <p class="task-trace-id mono">Trace <%= @selected_task_issue.issue_identifier %></p>
                  </div>
                  <button type="button" class="subtle-button" phx-click="clear_task_issue">Close</button>
                </div>

                <dl class="task-detail-list">
                  <div>
                    <dt>State</dt>
                    <dd><%= @selected_task_issue.state %></dd>
                  </div>
                  <div>
                    <dt>Project</dt>
                    <dd><%= @selected_task_issue.project_label %></dd>
                  </div>
                  <div>
                    <dt>Assignee</dt>
                    <dd><%= assignee_label(@selected_task_issue.assignee) %></dd>
                  </div>
                  <div>
                    <dt>Run status</dt>
                    <dd><%= @selected_task_issue.run_status.label %></dd>
                  </div>
                  <div>
                    <dt>Relations</dt>
                    <dd><%= @selected_task_issue.relations.label %></dd>
                  </div>
                  <div>
                    <dt>Updated</dt>
                    <dd><%= @selected_task_issue.updated_label %></dd>
                  </div>
                  <div :if={@selected_task_issue.run_status[:workspace_path]}>
                    <dt>Workspace</dt>
                    <dd class="mono path-text"><%= @selected_task_issue.run_status.workspace_path %></dd>
                  </div>
                  <div :if={@selected_task_issue.run_status[:session_id]}>
                    <dt>Session</dt>
                    <dd class="mono"><%= @selected_task_issue.run_status.session_id %></dd>
                  </div>
                  <div :if={@selected_task_issue.run_status[:error]}>
                    <dt>Last error</dt>
                    <dd><%= @selected_task_issue.run_status.error %></dd>
                  </div>
                </dl>

                <div class="task-detail-actions">
                  <a :if={@selected_task_issue.url} class="issue-link" href={@selected_task_issue.url} target="_blank" rel="noreferrer">
                    Open tracker
                  </a>
                  <a class="issue-link" href={"/api/v1/#{@selected_task_issue.issue_identifier}"}>
                    JSON details
                  </a>
                </div>
              <% else %>
                <p class="empty-state">Select an issue to inspect details.</p>
              <% end %>
            </aside>
          </div>
        </section>

        <section :if={@current_view == "overview"} id="runtime-queue" class="ops-panel" aria-labelledby="runtime-queue-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Runtime</p>
              <h2 id="runtime-queue-title" class="section-title">Runtime queue</h2>
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

        <section :if={@current_view == "diagnostics"} id="mcp-servers" class="ops-panel" aria-labelledby="mcp-servers-title">
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

        <section :if={@current_view == "runs"} id="runs" class="ops-panel" aria-labelledby="runs-title">
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

        <section :if={@current_view == "projects"} id="projects" class="ops-panel agent-config-panel" aria-labelledby="projects-title">
          <% visible_project_list = visible_projects(@payload.projects, @selected_project_id) %>
          <div class="section-header agent-config-header">
            <div>
              <p class="section-kicker">Agent Config</p>
              <h2 id="projects-title" class="section-title">Project command center</h2>
              <p class="section-copy">Project routing, workspace identity, and scoped controls.</p>
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

          <div class="agent-config-summary" aria-label="Agent configuration summary">
            <article class="agent-summary-card">
              <span class="agent-summary-label">Configured agents</span>
              <strong class="numeric"><%= length(visible_project_list) %></strong>
              <span>visible projects</span>
            </article>
            <article class="agent-summary-card">
              <span class="agent-summary-label">Active runs</span>
              <strong class="numeric"><%= visible_running_count(@payload, @selected_project_id) %></strong>
              <span>live sessions</span>
            </article>
            <article class="agent-summary-card">
              <span class="agent-summary-label">Retry queue</span>
              <strong class="numeric"><%= visible_retrying_count(@payload, @selected_project_id) %></strong>
              <span>waiting</span>
            </article>
            <article class="agent-summary-card">
              <span class="agent-summary-label">Next poll</span>
              <strong class="numeric"><%= format_polling(@payload.polling) %></strong>
              <span>global cadence</span>
            </article>
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
              class="project-form agent-config-form"
              phx-change="change_project_form"
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

          <%= if visible_project_list == [] do %>
            <p class="empty-state">No configured projects.</p>
          <% else %>
            <div class="project-command-grid">
              <article :for={project <- visible_project_list} class="project-command-card agent-config-card">
                <div class="project-card-header agent-card-header">
                  <div class="agent-card-identity">
                    <span class="agent-avatar" aria-hidden="true"><%= project_initials(project) %></span>
                    <div>
                      <h3 class="project-title"><%= project.name || project.id %></h3>
                      <p class="project-subtitle mono"><%= project.tracker_kind %> / <%= project.tracker_project_slug || "n/a" %></p>
                    </div>
                  </div>
                  <span class={health_badge_class(project.health.status)}><%= project.health.status %></span>
                </div>

                <dl class="project-detail-grid agent-config-grid">
                  <div class="agent-config-block agent-config-block-wide">
                    <dt>Workspace root</dt>
                    <dd class="mono path-text"><%= project.workspace_root %></dd>
                  </div>
                  <div class="agent-config-block agent-config-block-wide">
                    <dt>Repository</dt>
                    <dd class="mono path-text"><%= project.repository_path || "default hook" %></dd>
                  </div>
                  <div class="agent-config-block">
                    <dt>Active states</dt>
                    <dd><%= state_list(project.active_states) %></dd>
                  </div>
                  <div class="agent-config-block">
                    <dt>Terminal states</dt>
                    <dd><%= state_list(project.terminal_states) %></dd>
                  </div>
                  <div class="agent-config-block">
                    <dt>Git identity</dt>
                    <dd>
                      <div class="detail-stack">
                        <span :for={line <- git_identity_lines(project)} class="mono"><%= line %></span>
                      </div>
                    </dd>
                  </div>
                  <div class="agent-config-block">
                    <dt>Agent instructions</dt>
                    <dd><%= agent_instruction_status(project) %></dd>
                  </div>
                  <div class="agent-config-block">
                    <dt>Polling</dt>
                    <dd><%= project.polling.status %> · next <%= format_polling(project.polling) %></dd>
                  </div>
                  <div class="agent-config-block">
                    <dt>Last poll</dt>
                    <dd><%= poll_result_label(project.polling.last_result) %></dd>
                  </div>
                  <div class="agent-config-block">
                    <dt>Queue</dt>
                    <dd class="numeric">
                      <%= project.queue_counts.total %> total · <%= project.queue_counts.active_runs %> active · <%= project.queue_counts.retrying %> retrying
                    </dd>
                  </div>
                  <div class="agent-config-block">
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

                <div class="project-card-actions agent-action-row">
                  <div class="agent-action-primary">
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
                  </div>
                  <div class="agent-action-links">
                    <a href={dashboard_section_path(project.id, "tasks")} class="subtle-link">Tasks</a>
                    <a href={dashboard_section_path(project.id, "runs")} class="subtle-link">Runs</a>
                    <a href={dashboard_section_path(project.id, "settings")} class="subtle-link">Settings</a>
                    <a href={dashboard_section_path(project.id, "diagnostics")} class="subtle-link">Diagnostics</a>
                  </div>
                </div>
              </article>
            </div>
          <% end %>
        </section>

        <section :if={@current_view == "controls"} id="retry-controls" class="ops-panel" aria-labelledby="retry-controls-title">
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
          <section
            :if={@current_view == "controls"}
            id="claimed-controls"
            class="ops-panel"
            aria-labelledby="claimed-controls-title"
          >
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

        <section
          :if={@current_view == "controls"}
          id="controls"
          class="ops-panel workflow-builder-section"
          aria-labelledby="controls-title"
        >
          <div class="section-header">
            <div>
              <p class="section-kicker">Controls</p>
              <h2 id="controls-title" class="section-title">Workflow logic builder</h2>
              <p class="section-copy">Mock-only workflow composition for planning agent triggers, tasks, and branches.</p>
            </div>
            <span class="timestamp-pill">Mock mode</span>
          </div>

          <% selected_workflow_node = workflow_node(@workflow_selected_node_id) || default_workflow_node() %>

          <div class="workflow-builder" data-workflow-builder="mock">
            <aside class="workflow-library" aria-label="Node Library">
              <div class="workflow-panel-header">
                <h3>Node Library</h3>
                <span class="state-badge">Mock</span>
              </div>

              <section :for={group <- workflow_node_library()} class="workflow-library-group">
                <p class="workflow-group-label"><%= group.label %></p>
                <button
                  :for={node <- group.nodes}
                  type="button"
                  class={workflow_library_button_class(node.id, @workflow_selected_node_id)}
                  phx-click="select_workflow_node"
                  phx-value-node-id={node.id}
                  data-workflow-library-node={node.id}
                >
                  <span class={["workflow-node-mark", "workflow-node-mark-#{node.tone}"]} aria-hidden="true"><%= node.mark %></span>
                  <span>
                    <strong><%= node.label %></strong>
                    <small><%= node.description %></small>
                  </span>
                </button>
              </section>
            </aside>

            <section class="workflow-canvas" aria-label="Workflow canvas">
              <div class="workflow-canvas-toolbar">
                <div class="workflow-tool-group" aria-label="Canvas tools">
                  <button type="button" title="Zoom in" aria-label="Zoom in">+</button>
                  <button type="button" title="Zoom out" aria-label="Zoom out">-</button>
                  <button type="button" title="Fit canvas" aria-label="Fit canvas">Fit</button>
                </div>
                <span class="workflow-live-status">
                  <span></span>
                  Status: LIVE_READY
                </span>
              </div>

              <svg class="workflow-connector-map" viewBox="0 0 1000 420" aria-hidden="true" focusable="false">
                <path d="M182 126 C 270 126, 300 196, 392 196" />
                <path d="M578 196 C 650 196, 690 132, 770 132" />
                <path d="M578 196 C 650 196, 690 292, 770 292" />
              </svg>

              <div class="workflow-canvas-board">
                <button
                  :for={node <- workflow_canvas_nodes()}
                  type="button"
                  class={workflow_canvas_node_class(node, @workflow_selected_node_id)}
                  phx-click="select_workflow_node"
                  phx-value-node-id={node.id}
                  data-workflow-node-id={node.id}
                >
                  <span class="workflow-node-id"><%= node.identifier %></span>
                  <span class={["workflow-node-mark", "workflow-node-mark-#{node.tone}"]} aria-hidden="true"><%= node.mark %></span>
                  <strong><%= node.label %></strong>
                  <small><%= node.canvas_detail %></small>
                  <span class="workflow-node-progress" :if={node[:progress]}>
                    <span style={"width: #{node.progress}%"}></span>
                  </span>
                  <span class="workflow-node-ports" aria-hidden="true">
                    <span></span>
                    <span></span>
                  </span>
                </button>
              </div>
            </section>

            <aside class="workflow-properties" aria-label="Workflow properties">
              <div class="workflow-panel-header">
                <h3>Properties</h3>
                <span class="muted mono"><%= selected_workflow_node.identifier %></span>
              </div>

              <div class="workflow-selected-card">
                <span class={["workflow-node-mark", "workflow-node-mark-#{selected_workflow_node.tone}"]} aria-hidden="true">
                  <%= selected_workflow_node.mark %>
                </span>
                <div>
                  <p class="workflow-selected-title"><%= selected_workflow_node.label %></p>
                  <p class="workflow-selected-meta">AGENT_TYPE: <%= selected_workflow_node.kind %></p>
                </div>
              </div>

              <div class="workflow-property-stack">
                <label>
                  <span>System Prompt Override</span>
                  <textarea readonly rows="4"><%= selected_workflow_node.prompt %></textarea>
                </label>

                <label>
                  <span>Temperature (Precision)</span>
                  <input type="range" min="0" max="100" value={selected_workflow_node.temperature} disabled />
                </label>

                <label>
                  <span>Response Format</span>
                  <select disabled>
                    <option><%= selected_workflow_node.format %></option>
                  </select>
                </label>
              </div>

              <button
                id="workflow-preview-button"
                type="button"
                class="subtle-button workflow-preview-button"
                phx-click="preview_workflow_node"
              >
                Preview Node Output
              </button>

              <%= if @workflow_notice do %>
                <p class="form-notice" role="status"><%= @workflow_notice %></p>
              <% end %>

              <div class="workflow-operator-controls">
                <h3 class="control-title">Operator controls</h3>
                <p class="control-copy">Existing runtime actions remain explicit and outside mock canvas editing.</p>
                <div class="control-row">
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="refresh_now"
                    phx-disable-with="Refreshing"
                    data-confirm="Queue an immediate poll and reconciliation cycle?"
                    aria-label="Queue manual refresh"
                    title="Queue manual refresh"
                  >
                    Refresh
                  </button>
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="show_project_form"
                    aria-label="Open add project form"
                    title="Open add project form"
                  >
                    Add project
                  </button>
                </div>
              </div>
            </aside>
          </div>

          <button
            type="button"
            class="workflow-deploy-button"
            phx-click="mock_deploy_workflow"
            aria-label="Mock deploy workflow"
            title="Mock deploy workflow"
          >
            +
          </button>
        </section>

        <section :if={@current_view == "settings"} id="settings" class="ops-panel" aria-labelledby="settings-title">
          <% settings_project = selected_settings_project(@payload, @settings_project_id, @selected_project_id) %>
          <div class="section-header">
            <div>
              <p class="section-kicker">Settings</p>
              <h2 id="settings-title" class="section-title">Runtime settings</h2>
              <p class="section-copy">Read-only workflow values that shape dashboard behavior.</p>
            </div>
            <%= if settings_project do %>
              <div class="settings-project-switcher" data-settings-project={settings_project.id}>
                <button
                  type="button"
                  class="icon-button compact"
                  phx-click="cycle_settings_project"
                  phx-value-direction="previous"
                  disabled={settings_project_count(@payload) <= 1}
                  aria-label="Previous settings project"
                  title="Previous project"
                >
                  <span aria-hidden="true">&lt;</span>
                </button>
                <div class="settings-project-label">
                  <span>Project</span>
                  <strong><%= settings_project.name || settings_project.id %></strong>
                  <small><%= settings_project_position(@payload.projects, settings_project) %></small>
                </div>
                <button
                  type="button"
                  class="icon-button compact"
                  phx-click="cycle_settings_project"
                  phx-value-direction="next"
                  disabled={settings_project_count(@payload) <= 1}
                  aria-label="Next settings project"
                  title="Next project"
                >
                  <span aria-hidden="true">&gt;</span>
                </button>
              </div>
            <% end %>
          </div>

          <div class="settings-grid compact">
            <div :for={setting <- settings_rows(@payload, settings_project)} class="setting-row">
              <span class="setting-label"><%= setting.label %></span>
              <span class="setting-value"><%= setting.value %></span>
            </div>
          </div>
        </section>

        <% audit_entries =
          @payload
          |> audit_log_entries(@selected_project_id)
          |> filtered_audit_entries(@event_query) %>
        <% audit_inspector = audit_inspector_entry(@payload, @selected_project_id) %>
        <% audit_nodes = audit_node_health(@payload, @selected_project_id) %>

        <section :if={@current_view == "diagnostics"} id="diagnostics" class="ops-panel audit-log-panel" aria-labelledby="diagnostics-title">
          <div class="section-header audit-log-header">
            <div>
              <p class="section-kicker">Audit logs</p>
              <h2 id="diagnostics-title" class="section-title">Runtime audit stream</h2>
              <p class="section-copy">
                Live operational trace, payload inspection, and health signals for the current orchestration snapshot.
              </p>
            </div>
            <div class="link-group" aria-label="Diagnostic API links">
              <a href="/api/v1/state">State JSON</a>
              <a href="/api/v1/refresh">Refresh endpoint</a>
            </div>
          </div>

          <div class="audit-metric-grid">
            <article :for={metric <- audit_metrics(@payload, @selected_project_id, @now)} class={"audit-metric-card audit-metric-card-#{metric.variant}"}>
              <p class="metric-label"><%= metric.label %></p>
              <p class="metric-value numeric"><%= metric.value %></p>
              <p class="metric-detail"><%= metric.detail %></p>
            </article>
          </div>

          <div class="audit-console-grid">
            <section class="audit-terminal" aria-labelledby="audit-terminal-title">
              <div class="audit-window-bar">
                <div class="audit-window-title">
                  <span class="audit-window-dot audit-window-dot-danger"></span>
                  <span class="audit-window-dot audit-window-dot-accent"></span>
                  <span class="audit-window-dot audit-window-dot-success"></span>
                  <h3 id="audit-terminal-title">ORCHESTRUM_AUDIT_STREAM -- <%= selected_project_label(@payload, @selected_project_id) %></h3>
                </div>
                <span class="audit-window-meta numeric"><%= format_generated_at(@payload.generated_at) %></span>
              </div>

              <div class="audit-terminal-body">
                <%= if audit_entries == [] do %>
                  <p class="audit-console-empty">No matching audit events in the current snapshot.</p>
                <% else %>
                  <p :for={entry <- audit_entries} class={"audit-console-line audit-console-line-#{entry.level}"}>
                    <span class="audit-console-time"><%= entry.time %></span>
                    <span class="audit-console-level">[<%= String.upcase(entry.level) %>]</span>
                    <span class="audit-console-message"><%= entry.message %></span>
                  </p>
                <% end %>
              </div>

              <form id="audit-log-search-form" class="audit-command-line" phx-change="filter_events">
                <span aria-hidden="true">$</span>
                <input
                  type="search"
                  name="timeline[query]"
                  value={@event_query}
                  placeholder="Filter audit logs"
                  aria-label="Filter audit logs"
                  autocomplete="off"
                />
              </form>
            </section>

            <aside class="audit-inspector" aria-labelledby="audit-inspector-title">
              <div class="audit-inspector-header">
                <h3 id="audit-inspector-title">Inspector: <%= audit_inspector_title(audit_inspector) %></h3>
              </div>

              <div class="audit-inspector-body">
                <section class="audit-inspector-block">
                  <p class="metric-label">Metadata</p>
                  <dl class="audit-metadata-grid">
                    <div>
                      <dt>State</dt>
                      <dd><%= audit_inspector_status(audit_inspector) %></dd>
                    </div>
                    <div>
                      <dt>Session</dt>
                      <dd class="mono wrap-anywhere"><%= audit_inspector_session(audit_inspector) %></dd>
                    </div>
                    <div>
                      <dt>Project</dt>
                      <dd><%= audit_inspector_project(audit_inspector) %></dd>
                    </div>
                    <div>
                      <dt>Polling</dt>
                      <dd><%= format_polling(@payload.polling) %></dd>
                    </div>
                  </dl>
                </section>

                <section class="audit-inspector-block">
                  <p class="metric-label">Runtime payload</p>
                  <pre class="audit-code-panel"><%= pretty_value(audit_inspector_payload(audit_inspector)) %></pre>
                </section>

                <section class="audit-inspector-block">
                  <p class="metric-label">Rate limit payload</p>
                  <pre class="audit-code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
                </section>
              </div>
            </aside>
          </div>

          <div class="audit-secondary-grid">
            <section class="audit-analytics-panel" aria-labelledby="audit-token-title">
              <div class="audit-panel-header">
                <div>
                  <h3 id="audit-token-title">Token dynamics</h3>
                  <p>Usage allocation across the current snapshot.</p>
                </div>
              </div>

              <div class="audit-bar-chart" aria-label="Token usage chart">
                <div :for={bar <- audit_token_bars(@payload)} class="audit-bar-column">
                  <span class="audit-bar-value numeric"><%= bar.value %></span>
                  <span class={"audit-bar audit-bar-#{bar.variant}"} style={"height: #{bar.height}%"}></span>
                  <span class="audit-bar-label"><%= bar.label %></span>
                </div>
              </div>
            </section>

            <section class="audit-analytics-panel" aria-labelledby="audit-bottleneck-title">
              <div class="audit-panel-header audit-panel-header-compact">
                <h3 id="audit-bottleneck-title">Bottleneck analysis</h3>
              </div>

              <%= if audit_bottleneck_rows(@payload, @selected_project_id, @now) == [] do %>
                <p class="empty-state">No active or retrying agents in the selected scope.</p>
              <% else %>
                <table class="audit-bottleneck-table">
                  <thead>
                    <tr>
                      <th>Agent / task</th>
                      <th>Load time</th>
                      <th>Reliability</th>
                      <th>Signal</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={row <- audit_bottleneck_rows(@payload, @selected_project_id, @now)}>
                      <td>
                        <span class={"audit-status-dot audit-status-dot-#{row.variant}"}></span>
                        <span><%= row.label %></span>
                      </td>
                      <td class="numeric"><%= row.load_time %></td>
                      <td>
                        <span class="audit-reliability-track">
                          <span class={"audit-reliability-fill audit-reliability-fill-#{row.variant}"} style={"width: #{row.reliability}%"}></span>
                        </span>
                      </td>
                      <td><%= row.signal %></td>
                    </tr>
                  </tbody>
                </table>
              <% end %>
            </section>
          </div>

          <section class="audit-node-panel" aria-labelledby="audit-node-title">
            <h3 id="audit-node-title">Worker node health</h3>
            <div class="audit-node-grid">
              <span :for={node <- audit_nodes} class={"audit-node audit-node-#{node.variant}"}>
                <span><%= node.label %></span>
                <small><%= node.detail %></small>
              </span>
            </div>
          </section>

          <div class="audit-status-bar">
            <span><span class="audit-status-dot audit-status-dot-success"></span> SYS_STATUS: <%= audit_system_status(@payload, @selected_project_id) %></span>
            <span>UPTIME: <%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
            <span>LOAD_AVG: <%= visible_task_count(@payload, @selected_project_id) %> active/retry</span>
            <span>SYNCED TO ORCHESTRUM_STATE</span>
          </div>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload(filters, selected_issue_identifier) do
    payload = Presenter.state_payload(orchestrator(), snapshot_timeout_ms(), filters)

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

  defp assign_payload(socket) do
    filters = socket.assigns[:task_board_filters] || %{}
    selected_issue_identifier = socket.assigns[:selected_issue_identifier]
    selected_task_issue_identifier = socket.assigns[:selected_task_issue_identifier]
    payload = load_payload(filters, selected_issue_identifier)

    socket
    |> assign(:payload, payload)
    |> assign(:selected_task_issue, select_task_issue(payload, selected_task_issue_identifier))
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

  defp dashboard_primary_views, do: Enum.reject(@dashboard_views, &(&1.id == "settings"))

  defp view_from_params(%{"view" => view}, _action) when view in @view_ids, do: view
  defp view_from_params(_params, action), do: view_from_action(action)

  defp view_from_action(:show), do: "runs"

  defp view_from_action(action)
       when action in [:overview, :tasks, :runs, :projects, :controls, :settings, :diagnostics],
       do: Atom.to_string(action)

  defp view_from_action(_action), do: "overview"

  defp nav_link_class(view, view), do: "section-nav-link section-nav-link-active"
  defp nav_link_class(_view, _current_view), do: "section-nav-link"

  defp workflow_node_library do
    [
      %{
        label: "Triggers",
        nodes: [
          %{
            id: "incoming-webhook",
            label: "Webhook",
            description: "HTTP POST listener",
            identifier: "#tr-0192",
            kind: "WEBHOOK_TRIGGER",
            tone: "trigger",
            mark: "WH",
            position: "trigger",
            canvas_detail: "Endpoint: /v1/ingest",
            prompt: "Validate inbound payloads, normalize fields, and emit a structured research request.",
            temperature: 12,
            format: "JSON_SCHEMA",
            preview: "validated payload with topic, source, and urgency fields."
          },
          %{
            id: "scheduled-run",
            label: "Schedule",
            description: "Cron-based execution",
            identifier: "#tr-0440",
            kind: "CRON_TRIGGER",
            tone: "trigger",
            mark: "SC",
            position: "trigger",
            canvas_detail: "Every weekday at 09:00",
            prompt: "Create a scheduled run envelope and dispatch the workflow with the saved project context.",
            temperature: 8,
            format: "JSON_SCHEMA",
            preview: "scheduled run envelope with project context."
          }
        ]
      },
      %{
        label: "Agent Tasks",
        nodes: [
          %{
            id: "content-research",
            label: "Content Research",
            description: "LLM content reduction",
            identifier: "#agent-8842",
            kind: "GPT-4O_MINI",
            tone: "agent",
            mark: "AI",
            position: "agent",
            canvas_detail: "65% sample progress",
            progress: 65,
            prompt: "Research the requested topic, extract decisions, and summarize useful evidence for the next branch.",
            temperature: 34,
            format: "JSON_SCHEMA",
            preview: "JSON_READY summary with three evidence snippets."
          },
          %{
            id: "web-research",
            label: "Research",
            description: "Autonomous web search",
            identifier: "#agent-2711",
            kind: "SEARCH_AGENT",
            tone: "agent",
            mark: "RS",
            position: "agent",
            canvas_detail: "Search depth: focused",
            progress: 40,
            prompt: "Collect public context, discard low-confidence sources, and return citations for review.",
            temperature: 28,
            format: "MARKDOWN_MD",
            preview: "ranked source list and short confidence notes."
          }
        ]
      },
      %{
        label: "Logic",
        nodes: [
          %{
            id: "sentiment-filter",
            label: "Sentiment Filter",
            description: "If/Else branching",
            identifier: "#logic-55",
            kind: "IF_ELSE_BRANCH",
            tone: "logic",
            mark: "IF",
            position: "logic",
            canvas_detail: "Score > 0.85",
            prompt: "Route high-confidence outputs to storage and failed confidence checks to manual review.",
            temperature: 4,
            format: "BOOLEAN_BRANCH",
            preview: "PASS branch selected for confidence score 0.91."
          },
          %{
            id: "retry-loop",
            label: "Loop",
            description: "Iterative processing",
            identifier: "#loop-18",
            kind: "ITERATION_LOOP",
            tone: "logic",
            mark: "LP",
            position: "logic",
            canvas_detail: "Max passes: 3",
            prompt: "Retry low-confidence extraction up to three times before routing to manual review.",
            temperature: 16,
            format: "JSON_SCHEMA",
            preview: "loop completed on pass 2 with improved confidence."
          },
          %{
            id: "vector-store",
            label: "Vector DB Store",
            description: "Mock persistence sink",
            identifier: "#sink-02",
            kind: "VECTOR_SINK",
            tone: "sink",
            mark: "DB",
            position: "sink",
            canvas_detail: "Idle",
            prompt: "Persist approved embeddings and attach workflow run metadata for retrieval.",
            temperature: 0,
            format: "JSON_SCHEMA",
            preview: "mock write prepared with embedding id demo-248."
          }
        ]
      }
    ]
  end

  defp workflow_nodes do
    workflow_node_library()
    |> Enum.flat_map(& &1.nodes)
  end

  defp workflow_canvas_nodes do
    ["incoming-webhook", "content-research", "sentiment-filter", "vector-store"]
    |> Enum.map(&workflow_node/1)
    |> Enum.reject(&is_nil/1)
  end

  defp workflow_node(node_id) when is_binary(node_id) do
    Enum.find(workflow_nodes(), &(&1.id == node_id))
  end

  defp workflow_node(_node_id), do: nil

  defp default_workflow_node, do: workflow_node("content-research")

  defp workflow_library_button_class(node_id, selected_node_id) do
    [
      "workflow-library-node",
      node_id == selected_node_id && "workflow-library-node-selected"
    ]
  end

  defp workflow_canvas_node_class(node, selected_node_id) do
    [
      "workflow-canvas-node",
      "workflow-canvas-node-#{node.position}",
      "workflow-canvas-node-#{node.tone}",
      node.id == selected_node_id && "workflow-canvas-node-selected",
      node.id == "vector-store" && "workflow-canvas-node-muted"
    ]
  end

  defp dashboard_nav_count("overview", payload, project_id),
    do: visible_task_count(payload, project_id)

  defp dashboard_nav_count("tasks", payload, _project_id), do: task_board_count(payload)
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

  defp task_board_count(%{task_board: %{filtered_count: count}}) when is_integer(count), do: count
  defp task_board_count(_payload), do: 0

  defp task_board_query(%{task_board: %{filters: %{query: query}}}) when is_binary(query), do: query
  defp task_board_query(_payload), do: ""

  defp visible_task_count(payload, project_id),
    do: visible_running_count(payload, project_id) + visible_retrying_count(payload, project_id)

  defp visible_running_count(payload, project_id), do: payload |> visible_running(project_id) |> length()
  defp visible_retrying_count(payload, project_id), do: payload |> visible_retrying(project_id) |> length()

  defp visible_project_count(%{projects: projects}, project_id), do: projects |> visible_projects(project_id) |> length()
  defp visible_project_count(_payload, _project_id), do: 0

  defp audit_metrics(payload, project_id, now) do
    running_count = visible_running_count(payload, project_id)
    retrying_count = visible_retrying_count(payload, project_id)
    total_tokens = payload |> codex_total(:total_tokens) |> format_int()

    [
      %{
        label: "Active streams",
        value: Integer.to_string(running_count),
        detail: "#{visible_task_count(payload, project_id)} live/retry entries",
        variant: "accent"
      },
      %{
        label: "Retry pressure",
        value: Integer.to_string(retrying_count),
        detail: if(retrying_count == 0, do: "No queued retries", else: "Requires operator attention"),
        variant: if(retrying_count == 0, do: "success", else: "warning")
      },
      %{
        label: "Token volume",
        value: total_tokens,
        detail: "Completed plus active usage",
        variant: "accent"
      },
      %{
        label: "Runtime",
        value: format_runtime_seconds(total_runtime_seconds(payload, now)),
        detail: "Snapshot uptime window",
        variant: "neutral"
      }
    ]
  end

  defp audit_log_entries(payload, project_id) do
    running_entries =
      payload
      |> visible_running(project_id)
      |> Enum.map(&running_audit_entry(&1, payload))

    retry_entries =
      payload
      |> visible_retrying(project_id)
      |> Enum.map(&retry_audit_entry(&1, payload))

    running_entries ++ retry_entries ++ [polling_audit_entry(payload)]
  end

  defp filtered_audit_entries(entries, query) when is_list(entries) and is_binary(query) do
    normalized_query = query |> String.trim() |> String.downcase()

    if normalized_query == "" do
      entries
    else
      Enum.filter(entries, fn entry ->
        entry
        |> audit_entry_search_text()
        |> String.downcase()
        |> String.contains?(normalized_query)
      end)
    end
  end

  defp filtered_audit_entries(entries, _query) when is_list(entries), do: entries

  defp running_audit_entry(entry, payload) do
    message =
      [
        entry.issue_identifier,
        entry.last_event || "runtime",
        entry.last_message || "session active"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" - ")

    %{
      time: audit_entry_time(entry.last_event_at || entry.started_at || payload.generated_at),
      level: audit_level(message),
      message: message
    }
  end

  defp retry_audit_entry(entry, payload) do
    message =
      "#{entry.issue_identifier} - retry attempt #{entry.attempt || 0} queued" <>
        if(is_binary(entry.error) and entry.error != "", do: ": #{entry.error}", else: "")

    %{
      time: audit_entry_time(entry.due_at || payload.generated_at),
      level: "warn",
      message: message
    }
  end

  defp polling_audit_entry(payload) do
    %{
      time: audit_entry_time(payload.generated_at),
      level: "trace",
      message: "polling cadence #{format_poll_interval(payload.polling)}; next check #{format_polling(payload.polling)}"
    }
  end

  defp audit_entry_search_text(entry), do: Enum.join([entry.level, entry.time, entry.message], " ")

  defp audit_entry_time(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%H:%M:%S")

  defp audit_entry_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> audit_entry_time(datetime)
      _ -> value
    end
  end

  defp audit_entry_time(_value), do: "--:--:--"

  defp audit_level(message) when is_binary(message) do
    normalized = String.downcase(message)

    cond do
      String.contains?(normalized, ["fatal", "error", "failed", "exception"]) -> "error"
      String.contains?(normalized, ["warn", "retry", "degraded"]) -> "warn"
      String.contains?(normalized, ["trace", "token"]) -> "trace"
      true -> "info"
    end
  end

  defp audit_inspector_entry(payload, project_id) do
    case visible_running(payload, project_id) do
      [entry | _] ->
        %{kind: :running, entry: entry}

      [] ->
        case visible_retrying(payload, project_id) do
          [entry | _] -> %{kind: :retrying, entry: entry}
          [] -> %{kind: :snapshot, payload: payload, project_id: project_id}
        end
    end
  end

  defp audit_inspector_title(%{kind: :running, entry: %{issue_identifier: identifier}}), do: identifier
  defp audit_inspector_title(%{kind: :retrying, entry: %{issue_identifier: identifier}}), do: identifier
  defp audit_inspector_title(_inspector), do: "Snapshot"

  defp audit_inspector_status(%{kind: :running, entry: %{state: state}}), do: state || "running"
  defp audit_inspector_status(%{kind: :retrying}), do: "retrying"
  defp audit_inspector_status(_inspector), do: "idle"

  defp audit_inspector_session(%{kind: :running, entry: entry}), do: format_optional(entry.session_id)
  defp audit_inspector_session(%{kind: :retrying, entry: entry}), do: format_optional(entry.session_id)
  defp audit_inspector_session(_inspector), do: "n/a"

  defp audit_inspector_project(%{entry: %{project: project}}), do: project_label(project)
  defp audit_inspector_project(%{payload: payload, project_id: project_id}), do: selected_project_label(payload, project_id)
  defp audit_inspector_project(_inspector), do: "n/a"

  defp audit_inspector_payload(%{kind: :running, entry: entry}) do
    %{
      issue_identifier: entry.issue_identifier,
      state: entry.state,
      current_turn_id: entry.current_turn_id,
      turn_count: entry.turn_count,
      last_event: entry.last_event,
      last_message: entry.last_message,
      tokens: entry.tokens,
      workspace_path: entry.workspace_path
    }
  end

  defp audit_inspector_payload(%{kind: :retrying, entry: entry}) do
    %{
      issue_identifier: entry.issue_identifier,
      attempt: entry.attempt,
      due_at: entry.due_at,
      error: entry.error,
      workspace_path: entry.workspace_path
    }
  end

  defp audit_inspector_payload(%{payload: payload}) do
    %{
      counts: payload.counts,
      polling: payload.polling,
      codex_totals: payload.codex_totals
    }
  end

  defp audit_token_bars(payload) do
    raw_bars = [
      audit_token_bar(payload, "Input", :input_tokens, "input"),
      audit_token_bar(payload, "Output", :output_tokens, "output"),
      audit_token_bar(payload, "Total", :total_tokens, "total"),
      %{
        label: "Runtime",
        raw: payload |> codex_total(:seconds_running) |> round_number(),
        value: format_runtime_seconds(codex_total(payload, :seconds_running)),
        variant: "runtime"
      }
    ]

    max_value =
      raw_bars
      |> Enum.map(& &1.raw)
      |> Enum.max(fn -> 1 end)
      |> max(1)

    Enum.map(raw_bars, fn bar ->
      height = max(round(bar.raw / max_value * 100), 14)
      Map.put(bar, :height, height)
    end)
  end

  defp audit_token_bar(payload, label, key, variant) do
    raw = codex_total(payload, key)
    %{label: label, raw: raw, value: format_int(raw), variant: variant}
  end

  defp audit_bottleneck_rows(payload, project_id, now) do
    running_rows =
      payload
      |> visible_running(project_id)
      |> Enum.map(fn entry ->
        %{
          label: entry.issue_identifier,
          load_time: format_runtime_and_turns(entry.started_at, entry.turn_count, now),
          reliability: 92,
          signal: entry.last_message || entry.last_event || "active",
          variant: "success"
        }
      end)

    retry_rows =
      payload
      |> visible_retrying(project_id)
      |> Enum.map(fn entry ->
        %{
          label: entry.issue_identifier,
          load_time: "attempt #{entry.attempt || 0}",
          reliability: 42,
          signal: entry.error || "retry queued",
          variant: "warning"
        }
      end)

    running_rows ++ retry_rows
  end

  defp audit_node_health(payload, project_id) do
    nodes =
      (payload
       |> visible_running(project_id)
       |> Enum.map(fn entry ->
         %{label: entry.issue_identifier, detail: entry.worker_host || "active", variant: "success"}
       end)) ++
        (payload
         |> visible_retrying(project_id)
         |> Enum.map(fn entry ->
           %{label: entry.issue_identifier, detail: "retry #{entry.attempt || 0}", variant: "warning"}
         end))

    case nodes do
      [] -> [%{label: "IDLE", detail: "standby", variant: "idle"}]
      nodes -> Enum.take(nodes, 12)
    end
  end

  defp audit_system_status(payload, project_id) do
    if visible_retrying_count(payload, project_id) == 0, do: "NOMINAL", else: "ATTENTION"
  end

  defp selected_project_label(_payload, "all"), do: "all projects"

  defp selected_project_label(%{projects: projects}, project_id) when is_list(projects) do
    projects
    |> find_project(project_id)
    |> project_label()
  end

  defp selected_project_label(_payload, _project_id), do: "all projects"

  defp codex_total(%{codex_totals: totals}, key) when is_map(totals), do: number_value(Map.get(totals, key, 0))
  defp codex_total(_payload, _key), do: 0

  defp number_value(value) when is_integer(value), do: value
  defp number_value(value) when is_float(value), do: value
  defp number_value(_value), do: 0

  defp round_number(value) when is_number(value), do: round(value)

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

  defp selected_settings_project(%{projects: projects}, settings_project_id, selected_project_id) when is_list(projects) do
    find_project(projects, settings_project_id) ||
      find_project(projects, selected_project_id) ||
      List.first(projects)
  end

  defp selected_settings_project(_payload, _settings_project_id, _selected_project_id), do: nil

  defp cycled_settings_project_id([_ | _] = projects, current_project, direction) do
    project_count = length(projects)

    current_index =
      Enum.find_index(projects, fn project ->
        normalize_key(project.id) == normalize_key(current_project && current_project.id)
      end) || 0

    next_index =
      case direction do
        "previous" -> rem(current_index - 1 + project_count, project_count)
        "next" -> rem(current_index + 1, project_count)
        _direction -> current_index
      end

    projects
    |> Enum.at(next_index)
    |> Map.get(:id)
  end

  defp cycled_settings_project_id(_projects, _current_project, _direction), do: nil

  defp settings_project_count(%{projects: projects}) when is_list(projects), do: length(projects)
  defp settings_project_count(_payload), do: 0

  defp settings_project_position(projects, project) when is_list(projects) and is_map(project) do
    current_index =
      Enum.find_index(projects, fn candidate ->
        normalize_key(candidate.id) == normalize_key(project.id)
      end)

    case current_index do
      nil -> "1 / #{max(length(projects), 1)}"
      index -> "#{index + 1} / #{length(projects)}"
    end
  end

  defp settings_project_position(_projects, _project), do: "0 / 0"

  defp settings_rows(payload, project) do
    settings = Config.settings!()
    project = project || %{}

    settings_project_rows(project, settings) ++ settings_runtime_rows(payload, settings)
  end

  defp settings_project_rows(project, settings) do
    [
      %{label: "Tracker", value: project_setting(project, :tracker_kind, settings.tracker.kind, "n/a")},
      %{label: "Project slug", value: project_setting(project, :tracker_project_slug, settings.tracker.project_slug, "n/a")},
      %{label: "Active states", value: project_state_list(Map.get(project, :active_states) || settings.tracker.active_states)},
      %{label: "Terminal states", value: project_state_list(Map.get(project, :terminal_states) || settings.tracker.terminal_states)},
      %{label: "Workspace root", value: project_setting(project, :workspace_root, settings.workspace.root, "n/a")},
      %{label: "Repository", value: project_setting(project, :repository_path, nil, "default hook")},
      %{label: "Git identity", value: git_identity_lines(project) |> Enum.join(", ")},
      %{label: "Agent instructions", value: agent_instruction_status(project)}
    ]
  end

  defp settings_runtime_rows(payload, settings) do
    [
      %{label: "Polling interval", value: format_poll_interval(payload.polling)},
      %{label: "Snapshot timeout", value: "#{settings.observability.snapshot_timeout_ms} ms"},
      %{label: "Agent capacity", value: Integer.to_string(settings.agent.max_concurrent_agents)},
      %{label: "Max turns", value: Integer.to_string(settings.agent.max_turns)}
    ]
  end

  defp project_setting(project, key, fallback, default) do
    Map.get(project, key) || fallback || default
  end

  defp project_state_list(states) when is_list(states), do: Enum.join(states, ", ")
  defp project_state_list(_states), do: "n/a"

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

  defp project_initials(project) do
    project
    |> project_label()
    |> String.split(~r/[\s\-_\/]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
    |> case do
      "" -> "AG"
      initials -> String.slice(initials, 0, 2)
    end
  end

  defp assignee_label(nil), do: "Unassigned"
  defp assignee_label(""), do: "Unassigned"
  defp assignee_label(assignee), do: assignee

  defp selected_task_issue?(selected_identifier, issue) when is_binary(selected_identifier) do
    selected_identifier == issue.issue_identifier || selected_identifier == issue.issue_id
  end

  defp selected_task_issue?(_selected_identifier, _issue), do: false

  defp selected_task_issue_identifier(%{"issue" => issue}) when is_binary(issue) do
    case String.trim(issue) do
      "" -> nil
      selected -> selected
    end
  end

  defp selected_task_issue_identifier(_params), do: nil

  defp select_task_issue(_payload, nil), do: nil

  defp select_task_issue(%{task_board: %{issues: issues}}, selected_identifier) when is_binary(selected_identifier) do
    Enum.find(issues, &selected_task_issue?(selected_identifier, &1))
  end

  defp select_task_issue(_payload, _selected_identifier), do: nil

  defp task_board_path(filters, selected_identifier) do
    filters
    |> Presenter.normalize_task_board_filters()
    |> Enum.reduce(%{}, fn
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, Atom.to_string(key), value)
    end)
    |> maybe_put_issue_param(selected_identifier)
    |> URI.encode_query()
    |> case do
      "" -> "/"
      query -> "/tasks?" <> query
    end
  end

  defp maybe_put_issue_param(params, selected_identifier) when is_binary(selected_identifier) do
    case String.trim(selected_identifier) do
      "" -> params
      identifier -> Map.put(params, "issue", identifier)
    end
  end

  defp maybe_put_issue_param(params, _selected_identifier), do: params

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

  defp run_status_class("active"), do: "state-badge state-badge-active"
  defp run_status_class("retrying"), do: "state-badge state-badge-warning"
  defp run_status_class("idle"), do: "state-badge"
  defp run_status_class(_status), do: "state-badge state-badge-danger"

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
