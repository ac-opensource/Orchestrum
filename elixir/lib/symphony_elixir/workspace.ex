defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host, issue_context),
           :ok <- validate_workspace_path(workspace, worker_host, issue_context.workspace_root),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_bootstrap_repository(workspace, issue_context, created?, worker_host),
           :ok <- maybe_configure_git_identity(workspace, issue_context, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, worker_host), do: remove(workspace, worker_host, Config.settings!().workspace.root)

  defp remove(workspace, nil, workspace_root) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil, workspace_root) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  defp remove(workspace, worker_host, _workspace_root) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{} = issue, worker_host) do
    issue_context = issue_context(issue)
    safe_id = safe_identifier(issue_context.issue_identifier)

    case workspace_path_for_issue(safe_id, worker_host, issue_context) do
      {:ok, workspace} -> remove(workspace, worker_host, issue_context.workspace_root)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    issue_context = issue_context(identifier)
    safe_id = safe_identifier(issue_context.issue_identifier)

    case workspace_path_for_issue(safe_id, worker_host, issue_context) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    issue_context = issue_context(identifier)
    safe_id = safe_identifier(issue_context.issue_identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil, issue_context) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil, %{workspace_root: workspace_root}) when is_binary(safe_id) do
    workspace_root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host, %{workspace_root: workspace_root})
       when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(workspace_root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_bootstrap_repository(_workspace, _issue_context, false, _worker_host), do: :ok

  defp maybe_bootstrap_repository(workspace, %{repository_path: repository_path} = issue_context, true, nil)
       when is_binary(repository_path) do
    Logger.info("Cloning project repository #{issue_log_context(issue_context)} repository_path=#{repository_path} workspace=#{workspace} worker_host=local")

    case System.cmd("git", ["clone", "--depth", "1", repository_path, "."],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, {:repository_clone_failed, status, output}}
    end
  end

  defp maybe_bootstrap_repository(workspace, %{repository_path: repository_path} = issue_context, true, worker_host)
       when is_binary(repository_path) and is_binary(worker_host) do
    Logger.info("Cloning project repository #{issue_log_context(issue_context)} repository_path=#{repository_path} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      [
        remote_shell_assign("repository", repository_path),
        "git clone --depth 1 \"$repository\" ."
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{script}", Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:repository_clone_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_bootstrap_repository(_workspace, _issue_context, _created?, _worker_host), do: :ok

  defp maybe_configure_git_identity(workspace, %{git_identity: git_identity} = issue_context, nil)
       when map_size(git_identity) > 0 do
    case git_repository?(workspace, nil) do
      true ->
        configure_local_git_identity(workspace, issue_context, git_identity)

      false ->
        :ok
    end
  end

  defp maybe_configure_git_identity(workspace, %{git_identity: git_identity} = issue_context, worker_host)
       when map_size(git_identity) > 0 and is_binary(worker_host) do
    commands =
      git_identity
      |> git_identity_config()
      |> Enum.map(fn {key, value} -> "git config #{shell_escape(key)} #{shell_escape(value)}" end)

    script =
      [
        "cd #{shell_escape(workspace)}",
        "if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
        Enum.map(commands, &"  #{&1}"),
        "fi"
      ]
      |> List.flatten()
      |> Enum.join("\n")

    Logger.info("Configuring project git identity #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:git_identity_config_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_configure_git_identity(_workspace, _issue_context, _worker_host), do: :ok

  defp configure_local_git_identity(workspace, issue_context, git_identity) do
    Logger.info("Configuring project git identity #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    git_identity
    |> git_identity_config()
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      case System.cmd("git", ["-C", workspace, "config", key, value], stderr_to_stdout: true) do
        {_output, 0} -> {:cont, :ok}
        {output, status} -> {:halt, {:error, {:git_identity_config_failed, status, output}}}
      end
    end)
  end

  defp git_repository?(workspace, nil) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true) do
      {"true\n", 0} -> true
      _other -> false
    end
  end

  defp git_identity_config(git_identity) when is_map(git_identity) do
    [
      {"user.name", Map.get(git_identity, :name)},
      {"credential.username", Map.get(git_identity, :username)},
      {"user.email", Map.get(git_identity, :email)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil, workspace_root) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host, _workspace_root)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    project = Config.project_config_for_issue(issue)

    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      workspace_root: project.workspace_root,
      repository_path: project.repository_path,
      git_identity: git_identity(project)
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      workspace_root: Config.settings!().workspace.root,
      repository_path: nil,
      git_identity: %{}
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      workspace_root: Config.settings!().workspace.root,
      repository_path: nil,
      git_identity: %{}
    }
  end

  defp git_identity(project) do
    %{
      name: project.git_name,
      username: project.git_username,
      email: project.git_email
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
