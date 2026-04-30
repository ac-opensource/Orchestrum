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
      |> assign(:selected_project_id, "all")
      |> assign(:refresh_notice, nil)
      |> assign(:project_action_notice, nil)
      |> assign(:project_action_error, nil)
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
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selected_project_id, selected_project_id(params, socket.assigns.payload))}
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
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())
     |> assign(:project_action_notice, notice)
     |> assign(:project_action_error, error)}
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

        <section class="section-card" id="settings">
          <div class="section-header">
            <div>
              <h2 class="section-title">Projects</h2>
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
              <button type="button" class="icon-button" phx-click="show_project_form" aria-label="Add project" title="Add project">
                [+]
              </button>
            </div>
          </div>

          <%= if @project_form_notice do %>
            <p class="form-notice"><%= @project_form_notice %></p>
          <% end %>
          <%= if @project_action_notice do %>
            <p class="form-notice"><%= @project_action_notice %></p>
          <% end %>
          <%= if @project_action_error do %>
            <p class="form-error"><%= @project_action_error %></p>
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
                    <dd class="mono"><%= project.workspace_root %></dd>
                  </div>
                  <div>
                    <dt>Repository</dt>
                    <dd class="mono"><%= project.repository_path || "default hook" %></dd>
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
                  <a href={dashboard_section_path(project.id, "tasks")} class="subtle-link">Tasks</a>
                  <a href={dashboard_section_path(project.id, "runs")} class="subtle-link">Runs</a>
                  <a href={dashboard_section_path(project.id, "settings")} class="subtle-link">Settings</a>
                  <a href={dashboard_section_path(project.id, "diagnostics")} class="subtle-link">Diagnostics</a>
                </div>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card" id="diagnostics">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card" id="runs">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
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
                  <tr :for={entry <- visible_running(@payload, @selected_project_id)}>
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

        <section class="section-card" id="tasks">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if visible_retrying(@payload, @selected_project_id) == [] do %>
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
                  <tr :for={entry <- visible_retrying(@payload, @selected_project_id)}>
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

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
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

  defp visible_projects(projects, "all") when is_list(projects), do: projects

  defp visible_projects(projects, project_id) when is_list(projects) do
    projects
    |> Enum.filter(&(find_project([&1], project_id) != nil))
  end

  defp visible_running(%{running: running}, "all"), do: running

  defp visible_running(%{running: running, projects: projects}, project_id) do
    visible_entries(running, projects, project_id)
  end

  defp visible_retrying(%{retrying: retrying}, "all"), do: retrying

  defp visible_retrying(%{retrying: retrying, projects: projects}, project_id) do
    visible_entries(retrying, projects, project_id)
  end

  defp visible_entries(entries, projects, project_id) do
    case find_project(projects, project_id) do
      nil -> entries
      project -> Enum.filter(entries, &entry_for_project?(&1, project, projects))
    end
  end

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

  defp project_filter_path(project_id) when project_id in [nil, "", "all"], do: "/"

  defp project_filter_path(project_id) do
    "/?" <> URI.encode_query(%{"project" => project_id})
  end

  defp dashboard_section_path(project_id, section) do
    project_filter_path(project_id) <> "##{section}"
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
