defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Orchestrum's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/runs/:issue_identifier", DashboardLive, :show)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/task-board", ObservabilityApiController, :task_board)
    post("/api/v1/control/:control_action", ObservabilityApiController, :control)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/task-board", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/control/:control_action", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/control/polling/:action", ObservabilityApiController, :global_control)
    post("/api/v1/control/projects/:project_id/:action", ObservabilityApiController, :project_control)
    post("/api/v1/control/issues/:issue_identifier/:action", ObservabilityApiController, :issue_control)
    post("/api/v1/control/*path", ObservabilityApiController, :unsupported_control)
    match(:*, "/api/v1/control/*path", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
