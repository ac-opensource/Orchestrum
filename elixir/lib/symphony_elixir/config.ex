defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{LogFile, ProjectConfig}
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> workflow_server_port(settings!())
    end
  end

  @spec snapshot_timeout_ms() :: pos_integer()
  def snapshot_timeout_ms do
    settings!().observability.snapshot_timeout_ms
  end

  @spec orchestrator_state_path() :: Path.t()
  def orchestrator_state_path do
    case settings!().orchestrator.state_path do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        log_file =
          Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())

        log_file
        |> Path.expand()
        |> Path.dirname()
        |> Path.join("orchestrator_state.json")
    end
  end

  @spec project_configs() :: [ProjectConfig.t()]
  def project_configs do
    ProjectConfig.all(settings!())
  end

  @spec project_config_for_issue(term()) :: ProjectConfig.t()
  def project_config_for_issue(issue) do
    ProjectConfig.for_issue(settings!(), issue)
  end

  @spec workspace_root_for_issue(term()) :: Path.t()
  def workspace_root_for_issue(issue) do
    project_config_for_issue(issue).workspace_root
  end

  @spec repository_path_for_issue(term()) :: Path.t() | nil
  def repository_path_for_issue(issue) do
    project_config_for_issue(issue).repository_path
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, %{config: config}} <- Workflow.load(Workflow.workflow_file_path()),
         {:ok, settings} <- Schema.parse(config) do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    settings
    |> ProjectConfig.all()
    |> Enum.reduce_while(:ok, fn project, :ok ->
      case validate_project_semantics(project) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_project_semantics(%ProjectConfig{} = project) do
    cond do
      is_nil(project.tracker_kind) ->
        {:error, :missing_tracker_kind}

      project.tracker_kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, project.tracker_kind}}

      project.tracker_kind == "linear" and not is_binary(project.tracker_api_key) ->
        {:error, :missing_linear_api_token}

      project.tracker_kind == "linear" and not is_binary(project.tracker_project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp workflow_server_port(settings) do
    cond do
      settings.server.enabled == false -> nil
      is_integer(settings.server.port) and settings.server.port >= 0 -> settings.server.port
      true -> 4000
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
