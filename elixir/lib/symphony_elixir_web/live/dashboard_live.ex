defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Orchestrum.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, ProjectRegistry}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:refresh_notice, nil)
      |> assign(:task_filter, "all")
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
     |> assign(:payload, load_payload())
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
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())
     |> assign(:refresh_notice, notice)}
  end

  @impl true
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
  def handle_event("add_project", %{"project" => project_params}, socket) do
    case ProjectRegistry.add_project(project_params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> reset_project_form()
         |> assign(:payload, load_payload())
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
          </div>
        </div>
      </header>

      <nav class="section-nav" aria-label="Dashboard sections">
        <a class="section-nav-link" href="#overview">
          <span>Overview</span>
          <span class="nav-count numeric"><%= task_count(@payload) %></span>
        </a>
        <a class="section-nav-link" href="#tasks">
          <span>Tasks</span>
          <span class="nav-count numeric"><%= task_count(@payload) %></span>
        </a>
        <a class="section-nav-link" href="#runs">
          <span>Runs</span>
          <span class="nav-count numeric"><%= running_count(@payload) %></span>
        </a>
        <a class="section-nav-link" href="#projects">
          <span>Projects</span>
          <span class="nav-count numeric"><%= project_count(@payload) %></span>
        </a>
        <a class="section-nav-link" href="#controls">Controls</a>
        <a class="section-nav-link" href="#settings">Settings</a>
        <a class="section-nav-link" href="#diagnostics">Diagnostics</a>
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
                All <span class="numeric"><%= task_count(@payload) %></span>
              </button>
              <button
                type="button"
                class={task_filter_button_class(@task_filter, "running")}
                phx-click="filter_tasks"
                phx-value-filter="running"
                aria-pressed={to_string(@task_filter == "running")}
              >
                Running <span class="numeric"><%= running_count(@payload) %></span>
              </button>
              <button
                type="button"
                class={task_filter_button_class(@task_filter, "retrying")}
                phx-click="filter_tasks"
                phx-value-filter="retrying"
                aria-pressed={to_string(@task_filter == "retrying")}
              >
                Retrying <span class="numeric"><%= retrying_count(@payload) %></span>
              </button>
            </div>
          </div>

          <%= if task_filter_empty?(@payload, @task_filter) do %>
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
                    <tr :for={entry <- @payload.running}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
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
                    <tr :for={entry <- @payload.retrying}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
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

        <section id="runs" class="ops-panel" aria-labelledby="runs-title">
          <div class="section-header">
            <div>
              <p class="section-kicker">Runs</p>
              <h2 id="runs-title" class="section-title">Running sessions</h2>
              <p class="section-copy">Live agent runs with workspace, event, and token context.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
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
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
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
              <p class="section-copy">Configured project, workspace, and repository context.</p>
            </div>
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

          <%= if @project_form_notice do %>
            <p class="form-notice" role="status"><%= @project_form_notice %></p>
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

          <%= if @payload.projects == [] do %>
            <p class="empty-state">No configured projects.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table project-table">
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
                    <td class="mono path-text"><%= project.workspace_root %></td>
                    <td class="mono path-text"><%= project.repository_path || "default hook" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

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

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || Config.snapshot_timeout_ms()
  end

  defp task_count(%{running: running, retrying: retrying}), do: length(running) + length(retrying)
  defp task_count(_payload), do: 0

  defp running_count(%{running: running}), do: length(running)
  defp running_count(_payload), do: 0

  defp retrying_count(%{retrying: retrying}), do: length(retrying)
  defp retrying_count(_payload), do: 0

  defp project_count(%{projects: projects}), do: length(projects)
  defp project_count(_payload), do: 0

  defp task_filter_button_class(current, target) do
    if current == target do
      "segmented-button segmented-button-active"
    else
      "segmented-button"
    end
  end

  defp task_filter_empty?(payload, "running"), do: running_count(payload) == 0
  defp task_filter_empty?(payload, "retrying"), do: retrying_count(payload) == 0
  defp task_filter_empty?(payload, _filter), do: task_count(payload) == 0

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

  defp format_generated_at(generated_at) when is_binary(generated_at), do: generated_at
  defp format_generated_at(_generated_at), do: "n/a"

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
