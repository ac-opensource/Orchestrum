defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Orchestrum.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, ProjectRegistry, Tracker}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:refresh_notice, nil)
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
             |> assign(:payload, load_payload())
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
              <h2 class="section-title">MCP servers</h2>
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
                  <col style="width: 16rem;" />
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
                    <th>Reply</th>
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

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
