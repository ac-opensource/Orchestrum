defmodule SymphonyElixir.ProjectRegistry do
  @moduledoc """
  Persists project configuration updates into `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{ProjectConfig, Workflow, WorkflowStore}

  @key_order [
    "tracker",
    "kind",
    "endpoint",
    "api_key",
    "project_slug",
    "assignee",
    "active_states",
    "terminal_states",
    "polling",
    "interval_ms",
    "workspace",
    "root",
    "projects",
    "id",
    "name",
    "repository",
    "path",
    "worker",
    "ssh_hosts",
    "max_concurrent_agents_per_host",
    "agent",
    "max_concurrent_agents",
    "max_turns",
    "max_retry_backoff_ms",
    "max_concurrent_agents_by_state",
    "codex",
    "command",
    "approval_policy",
    "thread_sandbox",
    "turn_sandbox_policy",
    "turn_timeout_ms",
    "read_timeout_ms",
    "stall_timeout_ms",
    "hooks",
    "after_create",
    "before_run",
    "after_run",
    "before_remove",
    "timeout_ms",
    "observability",
    "dashboard_enabled",
    "refresh_ms",
    "render_interval_ms",
    "snapshot_timeout_ms",
    "server",
    "enabled",
    "port",
    "host",
    "orchestrator",
    "state_path"
  ]

  @type add_project_attrs :: %{optional(String.t() | atom()) => term()}
  @type add_project_error ::
          :project_name_required
          | :project_slug_required
          | :duplicate_project
          | {:workflow_write_failed, term()}
          | {:workflow_reload_failed, term()}
          | term()

  @spec add_project(add_project_attrs()) :: {:ok, ProjectConfig.t()} | {:error, add_project_error()}
  def add_project(attrs) when is_map(attrs) do
    path = Workflow.workflow_file_path()

    with {:ok, project_attrs} <- normalize_attrs(attrs),
         {:ok, %{config: config, prompt: prompt}} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(config),
         :ok <- ensure_unique_project(project_attrs, settings),
         updated_config <- append_project(config, settings, project_attrs),
         {:ok, updated_settings} <- Schema.parse(updated_config),
         :ok <- write_workflow(path, updated_config, prompt),
         :ok <- WorkflowStore.force_reload() do
      {:ok, find_added_project(updated_settings, project_attrs)}
    end
  end

  def add_project(_attrs), do: {:error, :invalid_project_input}

  defp normalize_attrs(attrs) do
    name = attrs |> get_attr(:name) |> normalize_required_string()
    project_slug = attrs |> get_attr(:project_slug) |> normalize_required_string()

    cond do
      is_nil(name) ->
        {:error, :project_name_required}

      is_nil(project_slug) ->
        {:error, :project_slug_required}

      true ->
        {:ok, %{id: project_slug, name: name, project_slug: project_slug}}
    end
  end

  defp get_attr(attrs, key), do: Map.get(attrs, to_string(key)) || Map.get(attrs, key)

  defp normalize_required_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_required_string(_value), do: nil

  defp ensure_unique_project(project_attrs, %Schema{} = settings) do
    new_keys = canonical_keys([project_attrs.id, project_attrs.name, project_attrs.project_slug])

    duplicate? =
      settings
      |> ProjectConfig.all()
      |> Enum.any?(fn project ->
        project
        |> project_keys()
        |> canonical_keys()
        |> Enum.any?(&(&1 in new_keys))
      end)

    if duplicate?, do: {:error, :duplicate_project}, else: :ok
  end

  defp project_keys(%ProjectConfig{} = project) do
    [project.id, project.name, project.tracker_project_slug]
  end

  defp canonical_keys(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp append_project(config, %Schema{} = settings, project_attrs) do
    projects =
      config
      |> Map.get("projects", [])
      |> normalize_project_entries(settings)
      |> Kernel.++([project_entry(project_attrs, settings)])

    Map.put(config, "projects", projects)
  end

  defp normalize_project_entries(nil, %Schema{} = settings), do: default_project_entries(settings)
  defp normalize_project_entries([], %Schema{} = settings), do: default_project_entries(settings)
  defp normalize_project_entries(projects, _settings) when is_list(projects), do: projects

  defp default_project_entries(%Schema{} = settings) do
    settings
    |> ProjectConfig.all()
    |> List.first()
    |> default_project_entry()
    |> List.wrap()
  end

  defp default_project_entry(%ProjectConfig{} = project) do
    %{
      "id" => project.id,
      "name" => project.name,
      "tracker" => %{
        "project_slug" => project.tracker_project_slug
      },
      "workspace" => %{
        "root" => project.workspace_root
      }
    }
  end

  defp project_entry(project_attrs, %Schema{} = settings) do
    %{
      "id" => project_attrs.id,
      "name" => project_attrs.name,
      "tracker" => %{
        "project_slug" => project_attrs.project_slug
      },
      "workspace" => %{
        "root" => settings.workspace.root
      }
    }
  end

  defp write_workflow(path, config, prompt) do
    case File.write(path, render_workflow(config, prompt)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workflow_write_failed, reason}}
    end
  end

  defp render_workflow(config, prompt) do
    "---\n" <> render_yaml(config) <> "---\n" <> prompt <> "\n"
  end

  defp find_added_project(%Schema{} = settings, project_attrs) do
    settings
    |> ProjectConfig.all()
    |> Enum.find(&(&1.tracker_project_slug == project_attrs.project_slug))
  end

  defp render_yaml(config) when is_map(config) do
    config
    |> dump_map(0)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp dump_map(map, indent) when is_map(map) do
    map
    |> ordered_entries()
    |> Enum.flat_map(fn {key, value} -> dump_key_value(to_string(key), value, indent) end)
  end

  defp dump_key_value(key, value, indent) when is_map(value) and map_size(value) == 0 do
    [spaces(indent) <> key <> ": {}"]
  end

  defp dump_key_value(key, value, indent) when is_map(value) do
    [spaces(indent) <> key <> ":"] ++ dump_map(value, indent + 2)
  end

  defp dump_key_value(key, [], indent), do: [spaces(indent) <> key <> ": []"]

  defp dump_key_value(key, value, indent) when is_list(value) do
    [spaces(indent) <> key <> ":"] ++ dump_list(value, indent + 2)
  end

  defp dump_key_value(key, value, indent) do
    [spaces(indent) <> key <> ": " <> yaml_scalar(value)]
  end

  defp dump_list(values, indent) do
    Enum.flat_map(values, fn
      value when is_map(value) ->
        [spaces(indent) <> "-"] ++ dump_map(value, indent + 2)

      value ->
        [spaces(indent) <> "- " <> yaml_scalar(value)]
    end)
  end

  defp ordered_entries(map) do
    Enum.sort_by(Map.to_list(map), fn {key, _value} ->
      key = to_string(key)

      case Enum.find_index(@key_order, &(&1 == key)) do
        nil -> {1, key}
        index -> {0, index}
      end
    end)
  end

  defp yaml_scalar(value), do: Jason.encode!(value)

  defp spaces(count), do: String.duplicate(" ", count)
end
