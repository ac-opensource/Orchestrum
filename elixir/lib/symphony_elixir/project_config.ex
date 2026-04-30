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
      |> Enum.any?(&(&1 in issue_keys))
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
      terminal_states: project.terminal_states,
      health: health_summary(project)
    }
  end

  @spec health_summary(t()) :: map()
  def health_summary(%__MODULE__{} = project) do
    problems =
      []
      |> add_problem(tracker_kind_problem(project))
      |> add_problem(tracker_auth_problem(project))
      |> add_problem(tracker_slug_problem(project))
      |> add_problem(workspace_root_problem(project))
      |> add_problem(repository_path_problem(project))
      |> Enum.reverse()

    %{
      status: health_status(problems),
      problems: problems
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

  @spec project_keys(t()) :: [String.t()]
  defp project_keys(%__MODULE__{} = project) do
    [project.id, project.name, project.tracker_project_slug]
    |> Enum.filter(&is_binary/1)
  end

  @spec issue_project_keys(term()) :: [String.t()]
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
    |> Enum.filter(&is_binary/1)
  end

  defp issue_project_keys(%{project_id: project_id}) when is_binary(project_id) do
    [project_id]
  end

  defp issue_project_keys(_issue), do: []

  defp tracker_kind_problem(%__MODULE__{tracker_kind: nil}) do
    problem(:missing_tracker_kind, "Tracker kind is missing.")
  end

  defp tracker_kind_problem(%__MODULE__{tracker_kind: tracker_kind}) when tracker_kind not in ["linear", "memory"] do
    problem(:unsupported_tracker_kind, "Tracker kind is unsupported: #{tracker_kind}.")
  end

  defp tracker_kind_problem(_project), do: nil

  defp tracker_auth_problem(%__MODULE__{tracker_kind: "linear", tracker_api_key: api_key})
       when not is_binary(api_key) do
    problem(:missing_auth, "Linear API credentials are missing.")
  end

  defp tracker_auth_problem(_project), do: nil

  defp tracker_slug_problem(%__MODULE__{tracker_kind: "linear", tracker_project_slug: project_slug})
       when not is_binary(project_slug) do
    problem(:missing_project_slug, "Linear project slug is missing.")
  end

  defp tracker_slug_problem(%__MODULE__{tracker_kind: "linear", tracker_project_slug: project_slug}) do
    if String.trim(project_slug) == "" do
      problem(:missing_project_slug, "Linear project slug is missing.")
    end
  end

  defp tracker_slug_problem(_project), do: nil

  defp workspace_root_problem(%__MODULE__{workspace_root: workspace_root}) do
    cond do
      not is_binary(workspace_root) or String.trim(workspace_root) == "" ->
        problem(:invalid_workspace_path, "Workspace root is missing.")

      String.contains?(workspace_root, ["\n", "\r", <<0>>]) ->
        problem(:invalid_workspace_path, "Workspace root contains invalid characters.")

      File.exists?(Path.expand(workspace_root)) and not File.dir?(Path.expand(workspace_root)) ->
        problem(:invalid_workspace_path, "Workspace root is not a directory: #{workspace_root}.")

      true ->
        nil
    end
  end

  defp repository_path_problem(%__MODULE__{repository_path: nil}), do: nil

  defp repository_path_problem(%__MODULE__{repository_path: repository_path}) when is_binary(repository_path) do
    cond do
      String.trim(repository_path) == "" ->
        problem(:repository_setup_failed, "Repository path is blank.")

      String.contains?(repository_path, ["\n", "\r", <<0>>]) ->
        problem(:repository_setup_failed, "Repository path contains invalid characters.")

      local_repository_path?(repository_path) and not File.exists?(Path.expand(repository_path)) ->
        problem(:repository_setup_failed, "Repository path does not exist: #{repository_path}.")

      local_repository_path?(repository_path) and File.exists?(Path.expand(repository_path)) and
          not File.dir?(Path.expand(repository_path)) ->
        problem(:repository_setup_failed, "Repository path is not a directory: #{repository_path}.")

      true ->
        nil
    end
  end

  defp repository_path_problem(_project), do: nil

  defp local_repository_path?(path) when is_binary(path) do
    Path.type(path) == :absolute or String.starts_with?(path, ["./", "../", "~/"])
  end

  defp health_status(problems) do
    if problems == [], do: "healthy", else: "error"
  end

  defp add_problem(problems, nil), do: problems
  defp add_problem(problems, problem), do: [problem | problems]

  defp problem(code, message) do
    %{code: to_string(code), severity: "error", message: message}
  end
end
