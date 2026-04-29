defmodule SymphonyElixir.Tracker.Unsupported do
  @moduledoc false

  @behaviour SymphonyElixir.Tracker

  @spec fetch_candidate_issues() :: {:error, term()}
  def fetch_candidate_issues, do: unsupported_read()

  @spec fetch_issues_by_states([String.t()]) :: {:error, term()}
  def fetch_issues_by_states(_states), do: unsupported_read()

  @spec fetch_issue_states_by_ids([String.t()]) :: {:error, term()}
  def fetch_issue_states_by_ids(_issue_ids), do: unsupported_read()

  @spec create_comment(String.t(), String.t()) :: {:error, term()}
  def create_comment(_issue_id, _body), do: unsupported_write()

  @spec update_issue_state(String.t(), String.t()) :: {:error, term()}
  def update_issue_state(_issue_id, _state_name), do: unsupported_write()

  defp unsupported_read do
    {:error, {:unsupported_tracker_kind, tracker_kind()}}
  end

  defp unsupported_write do
    {:error, {:unsupported_tracker_write, tracker_kind()}}
  end

  defp tracker_kind do
    case SymphonyElixir.Config.settings!().tracker.kind do
      kind when is_binary(kind) -> kind
      _ -> "unknown"
    end
  end
end
