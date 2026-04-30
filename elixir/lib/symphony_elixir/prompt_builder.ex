defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @agent_instruction_files ["AGENTS.md", "AGENT.md", "agents.md", "agent.md"]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    rendered_prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    case project_agent_instructions(Keyword.get(opts, :workspace)) do
      nil ->
        rendered_prompt

      instructions ->
        instructions <> "\n\n" <> rendered_prompt
    end
  end

  defp project_agent_instructions(workspace) when is_binary(workspace) do
    Enum.find_value(@agent_instruction_files, &read_agent_instruction_file(workspace, &1))
    |> case do
      nil ->
        nil

      {filename, content} ->
        """
        Project-local agent instructions from #{filename}:

        #{content}
        """
        |> String.trim_trailing()
    end
  end

  defp project_agent_instructions(_workspace), do: nil

  defp read_agent_instruction_file(workspace, filename) do
    path = Path.join(workspace, filename)

    case File.regular?(path) do
      true -> read_agent_instruction_content(path, filename)
      false -> nil
    end
  end

  defp read_agent_instruction_content(path, filename) do
    content = File.read!(path)

    case String.trim(content) do
      "" -> nil
      _content -> {filename, String.trim_trailing(content)}
    end
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
