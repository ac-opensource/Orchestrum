defmodule SymphonyElixir.AgentInstructions do
  @moduledoc false

  @filenames ["AGENTS.md", "AGENT.md", "agents.md", "agent.md"]

  @spec filenames() :: [String.t()]
  def filenames, do: @filenames

  @spec read(Path.t() | nil) :: {String.t(), String.t()} | nil
  def read(workspace) when is_binary(workspace) do
    case find_file(workspace) do
      {filename, path} -> read_content(path, filename)
      nil -> nil
    end
  end

  def read(_workspace), do: nil

  @spec find_file(Path.t() | nil) :: {String.t(), Path.t()} | nil
  def find_file(root) when is_binary(root) do
    Enum.find_value(@filenames, fn filename ->
      path = Path.join(root, filename)

      if File.regular?(path), do: {filename, path}
    end)
  end

  def find_file(_root), do: nil

  defp read_content(path, filename) do
    content = File.read!(path)

    case String.trim(content) do
      "" -> nil
      _content -> {filename, String.trim_trailing(content)}
    end
  end
end
