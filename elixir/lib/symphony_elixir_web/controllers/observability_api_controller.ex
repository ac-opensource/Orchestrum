defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Orchestrum observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Config
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec task_board(Conn.t(), map()) :: Conn.t()
  def task_board(conn, params) do
    case Presenter.task_board_payload(orchestrator(), snapshot_timeout_ms(), params) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, {:invalid_request, message}} ->
        error_response(conn, 400, "invalid_request", message)

      {:error, {:tracker_error, reason}} ->
        error_response(conn, 502, "tracker_error", "Tracker request failed", %{reason: inspect(reason)})
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec project_refresh(Conn.t(), map()) :: Conn.t()
  def project_refresh(conn, %{"project_id" => project_id}) do
    case Presenter.project_refresh_payload(project_id, orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :project_not_found} ->
        error_response(conn, 404, "project_not_found", "Project not found")

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec control(Conn.t(), map()) :: Conn.t()
  def control(conn, %{"control_action" => control_action} = params) do
    params = Map.delete(params, "control_action")

    case Presenter.control_payload(control_action, params, orchestrator()) do
      {:ok, status, payload} ->
        conn
        |> put_status(status)
        |> json(payload)

      {:error, status, payload} ->
        conn
        |> put_status(status)
        |> json(payload)
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message, details \\ nil) do
    error =
      if is_nil(details) do
        %{code: code, message: message}
      else
        %{code: code, message: message, details: details}
      end

    conn
    |> put_status(status)
    |> json(%{error: error})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || Config.snapshot_timeout_ms()
  end
end
