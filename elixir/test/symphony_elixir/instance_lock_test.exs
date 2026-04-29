defmodule SymphonyElixir.InstanceLockTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.InstanceLock

  test "creates a lock file and removes it on clean shutdown" do
    path = temp_lock_path()
    name = unique_name()

    assert {:ok, pid} = InstanceLock.start_link(path: path, name: name)
    assert File.read!(path) =~ "pid=#{System.pid()}"

    GenServer.stop(pid)
    refute File.exists?(path)
  end

  test "refuses to start when an existing lock pid is still alive" do
    path = temp_lock_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "pid=123\n")

    assert {:error, {:orchestrum_instance_already_running, locked_path, 123}} =
             InstanceLock.start_link(path: path, name: unique_name(), pid_checker: fn 123 -> true end)

    assert locked_path == Path.expand(path)
  end

  test "replaces a stale lock file" do
    path = temp_lock_path()
    name = unique_name()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "pid=123\n")

    assert {:ok, pid} = InstanceLock.start_link(path: path, name: name, pid_checker: fn 123 -> false end)
    assert File.read!(path) =~ "pid=#{System.pid()}"

    GenServer.stop(pid)
  end

  defp temp_lock_path do
    Path.join(System.tmp_dir!(), "orchestrum-instance-lock-#{System.unique_integer([:positive])}/state.json.lock")
  end

  defp unique_name do
    Module.concat(__MODULE__, :"Lock#{System.unique_integer([:positive])}")
  end
end
