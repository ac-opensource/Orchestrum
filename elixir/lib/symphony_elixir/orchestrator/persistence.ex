defmodule SymphonyElixir.Orchestrator.Persistence do
  @moduledoc false

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        Jason.decode(contents)

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(path, payload) when is_binary(path) and is_map(payload) do
    tmp_path = path <> ".tmp-#{System.unique_integer([:positive])}"

    result =
      case Jason.encode(payload) do
        {:ok, json} -> write_json(path, tmp_path, json)
        {:error, reason} -> {:error, reason}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp write_json(path, tmp_path, json) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp_path, json <> "\n") do
      File.rename(tmp_path, path)
    end
  end
end
