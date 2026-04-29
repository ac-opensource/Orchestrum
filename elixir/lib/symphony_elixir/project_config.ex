defmodule SymphonyElixir.ProjectConfig do
  @moduledoc """
  Effective per-project configuration derived from `WORKFLOW.md`.

  Top-level tracker/workspace settings remain the default single-project
  contract. Entries under `projects` inherit those defaults and override only
  the project-specific parts they need.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

  defstruct [
    :id,
    :name,
    :tracker_kind,
    :tracker_endpoint,
    :tracker_api_key,
    :tracker_project_slug,
    :tracker_assignee,
    :workspace_root,
    :repository_path,
    active_states: [],
    terminal_states: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          tracker_kind: String.t() | nil,
          tracker_endpoint: String.t() | nil,
          tracker_api_key: String.t() | nil,
          tracker_project_slug: String.t() | nil,
          tracker_assignee: String.t() | nil,
          workspace_root: Path.t(),
          repository_path: Path.t() | nil,
          active_states: [String.t()],
          terminal_states: [String.t()]
        }

  @spec all() :: [t()]
  def all do
    Config.settings!()
    |> all()
  end

  @spec all(Schema.t()) :: [t()]
  def all(%Schema{} = settings) do
    case settings.projects do
      [] ->
        [default_project(settings)]

      projects ->
        projects
        |> Enum.with_index(1)
        |> Enum.map(fn {project, index} -> from_project(project, settings, index) end)
    end
  end

  @spec default() :: t()
  def default do
    Config.settings!()
    |> default_project()
  end

  @spec for_issue(term()) :: t()
  def for_issue(issue) do
    Config.settings!()
    |> for_issue(issue)
  end

  @spec for_issue(Schema.t(), term()) :: t()
  def for_issue(%Schema{} = settings, issue) do
    projects = all(settings)
    issue_keys = issue_project_keys(issue)

    Enum.find(projects, fn project ->
      project_keys(project)
      |> Enum.any?(&MapSet.member?(issue_keys, &1))
    end) || List.first(projects) || default_project(settings)
  end

  @spec active_state_names(term()) :: [String.t()]
  def active_state_names(issue), do: for_issue(issue).active_states

  @spec terminal_state_names(term()) :: [String.t()]
  def terminal_state_names(issue), do: for_issue(issue).terminal_states

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = project) do
    %{
      id: project.id,
      name: project.name,
      tracker_kind: project.tracker_kind,
      tracker_project_slug: project.tracker_project_slug,
      workspace_root: project.workspace_root,
      repository_path: project.repository_path,
      active_states: project.active_states,
      terminal_states: project.terminal_states
    }
  end

  defp default_project(%Schema{} = settings) do
    %__MODULE__{
      id: default_id(settings.tracker.project_slug),
      name: default_name(settings.tracker.project_slug),
      tracker_kind: settings.tracker.kind,
      tracker_endpoint: settings.tracker.endpoint,
      tracker_api_key: settings.tracker.api_key,
      tracker_project_slug: settings.tracker.project_slug,
      tracker_assignee: settings.tracker.assignee,
      active_states: settings.tracker.active_states,
      terminal_states: settings.tracker.terminal_states,
      workspace_root: settings.workspace.root,
      repository_path: nil
    }
  end

  defp from_project(project, %Schema{} = settings, index) do
    id = project_id(project, index)
    name = project_name(project, id)

    %__MODULE__{
      id: id,
      name: name,
      tracker_kind: inherit(project.tracker.kind, settings.tracker.kind),
      tracker_endpoint: inherit(project.tracker.endpoint, settings.tracker.endpoint),
      tracker_api_key: inherit(project.tracker.api_key, settings.tracker.api_key),
      tracker_project_slug: inherit(project.tracker.project_slug, settings.tracker.project_slug),
      tracker_assignee: inherit(project.tracker.assignee, settings.tracker.assignee),
      active_states: inherit(project.tracker.active_states, settings.tracker.active_states),
      terminal_states: inherit(project.tracker.terminal_states, settings.tracker.terminal_states),
      workspace_root: inherit(project.workspace.root, settings.workspace.root),
      repository_path: project.repository.path
    }
  end

  defp default_id(project_slug), do: normalize_id(project_slug) || "default"
  defp default_name(project_slug), do: normalize_id(project_slug) || "Default"

  defp project_id(project, index) do
    normalize_id(project.id) || normalize_id(project.tracker.project_slug) || "project-#{index}"
  end

  defp project_name(project, id), do: normalize_id(project.name) || id

  defp inherit(nil, fallback), do: fallback
  defp inherit(value, _fallback), do: value

  defp normalize_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_id(_value), do: nil

  defp project_keys(%__MODULE__{} = project) do
    [project.id, project.name, project.tracker_project_slug]
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp issue_project_keys(%{project: project}) when is_map(project) do
    [
      project[:id],
      project["id"],
      project[:name],
      project["name"],
      project[:slug],
      project["slug"],
      project[:slug_id],
      project["slugId"],
      project["slug_id"]
    ]
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp issue_project_keys(%{project_id: project_id}) when is_binary(project_id) do
    MapSet.new([project_id])
  end

  defp issue_project_keys(_issue), do: MapSet.new()
end
