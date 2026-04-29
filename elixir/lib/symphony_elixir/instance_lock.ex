defmodule SymphonyElixir.InstanceLock do
  @moduledoc """
  Prevents multiple Orchestrum instances from sharing one state/log directory.
  """

  use GenServer

  alias SymphonyElixir.Config

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    path = Keyword.get(opts, :path, default_lock_path())
    name = Keyword.get(opts, :name, __MODULE__)
    pid_checker = Keyword.get(opts, :pid_checker, &pid_alive?/1)
    owner_pid = Keyword.get(opts, :owner_pid, System.pid())

    case acquire(path, owner_pid, pid_checker) do
      {:ok, lock} ->
        GenServer.start_link(__MODULE__, lock, name: name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec default_lock_path() :: Path.t()
  def default_lock_path do
    Config.orchestrator_state_path() <> ".lock"
  end

  @impl true
  def init(lock) do
    Process.flag(:trap_exit, true)
    {:ok, lock}
  end

  @impl true
  def terminate(_reason, %{path: path}) do
    _ = File.rm(path)
    :ok
  end

  defp acquire(path, owner_pid, pid_checker) do
    expanded_path = Path.expand(path)
    :ok = File.mkdir_p(Path.dirname(expanded_path))

    case File.open(expanded_path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, lock_contents(owner_pid))
        File.close(io)
        {:ok, %{path: expanded_path}}

      {:error, :eexist} ->
        handle_existing_lock(expanded_path, owner_pid, pid_checker)

      {:error, reason} ->
        {:error, {:instance_lock_failed, expanded_path, reason}}
    end
  end

  defp handle_existing_lock(path, owner_pid, pid_checker) do
    case existing_lock_pid(path) do
      {:ok, pid} ->
        if pid_checker.(pid) do
          {:error, {:orchestrum_instance_already_running, path, pid}}
        else
          replace_stale_lock(path, owner_pid, pid_checker)
        end

      :error ->
        replace_stale_lock(path, owner_pid, pid_checker)
    end
  end

  defp replace_stale_lock(path, owner_pid, pid_checker) do
    case File.rm(path) do
      :ok -> acquire(path, owner_pid, pid_checker)
      {:error, :enoent} -> acquire(path, owner_pid, pid_checker)
      {:error, reason} -> {:error, {:instance_lock_failed, path, reason}}
    end
  end

  defp lock_contents(owner_pid) do
    """
    pid=#{owner_pid}
    started_at=#{DateTime.utc_now() |> DateTime.to_iso8601()}
    """
  end

  defp existing_lock_pid(path) do
    with {:ok, contents} <- File.read(path),
         [_, pid] <- Regex.run(~r/^pid=(\d+)$/m, contents),
         {parsed_pid, ""} <- Integer.parse(pid) do
      {:ok, parsed_pid}
    else
      _ -> :error
    end
  end

  defp pid_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp pid_alive?(_pid), do: false
end
