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
        |> put_status(refresh_status(payload))
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec control(Conn.t(), map()) :: Conn.t()
  def control(conn, %{"control_action" => control_action} = params) do
    params = Map.delete(params, "control_action")

    if authorized_control_request?(conn) do
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
    else
      error_response(conn, 401, "unauthorized", "Control token is invalid")
    end
  end

  @spec global_control(Conn.t(), map()) :: Conn.t()
  def global_control(conn, %{"action" => action}) do
    control_response(conn, global_control_action(action), nil)
  end

  @spec project_control(Conn.t(), map()) :: Conn.t()
  def project_control(conn, %{"project_id" => project_id, "action" => action}) do
    control_response(conn, project_control_action(action), project_id)
  end

  @spec issue_control(Conn.t(), map()) :: Conn.t()
  def issue_control(conn, %{"issue_identifier" => issue_identifier, "action" => action}) do
    control_response(conn, issue_control_action(action), issue_identifier)
  end

  @spec unsupported_control(Conn.t(), map()) :: Conn.t()
  def unsupported_control(conn, params) do
    control_response(conn, "unsupported_action", params["path"])
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

  defp control_response(conn, action, target) do
    cond do
      !authorized_control_request?(conn) ->
        error_response(conn, 401, "unauthorized", "Control token is invalid")

      action == "unsupported_action" ->
        error_response(conn, 422, "unsupported_action", "Unsupported orchestrator control")

      true ->
        case Presenter.control_payload(orchestrator(), action, target) do
          {:ok, %{ok: false} = payload} ->
            conn
            |> put_status(control_error_status(payload))
            |> json(payload)

          {:ok, payload} ->
            conn
            |> put_status(control_success_status(payload))
            |> json(payload)

          {:error, :unavailable} ->
            error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
        end
    end
  end

  defp authorized_control_request?(conn) do
    case Endpoint.config(:control_token) do
      token when is_binary(token) and token != "" ->
        token in get_req_header(conn, "x-orchestrum-control-token")

      _ ->
        true
    end
  end

  defp refresh_status(%{rejected: true}), do: 409
  defp refresh_status(_payload), do: 202

  defp control_success_status(%{status: status}) when status in ["queued", "coalesced"], do: 202
  defp control_success_status(_payload), do: 200

  defp control_error_status(%{code: "project_not_found"}), do: 404
  defp control_error_status(%{code: "retry_not_found"}), do: 404
  defp control_error_status(%{code: "claim_not_found"}), do: 404
  defp control_error_status(%{code: "unsupported_action"}), do: 422
  defp control_error_status(_payload), do: 409

  defp global_control_action("pause"), do: "pause_global"
  defp global_control_action("resume"), do: "resume_global"
  defp global_control_action(_action), do: "unsupported_action"

  defp project_control_action("pause"), do: "pause_project"
  defp project_control_action("resume"), do: "resume_project"
  defp project_control_action("dispatch"), do: "dispatch_project_now"
  defp project_control_action(_action), do: "unsupported_action"

  defp issue_control_action("cancel"), do: "cancel_run"
  defp issue_control_action("retry"), do: "retry_now"
  defp issue_control_action("clear_retry"), do: "clear_retry"
  defp issue_control_action("release_claim"), do: "release_claim"
  defp issue_control_action(_action), do: "unsupported_action"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || Config.snapshot_timeout_ms()
  end
end
