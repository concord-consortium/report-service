defmodule ReportServer.PostProcessing.Steps.GlossaryData do
  require Logger

  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers
  alias ReportServerWeb.{ReportService, PortalReport}

  @id "glossary_data"
  @learner_id "learner_id"
  @remote_endpoint "remote_endpoint"
  @resource_url "resource_url"
  @offering_id "offering_id"

  @staging_firebase_app "report-service-dev"
  @prod_firebase_app "report-service-pro"

  def step do
    %Step{
      id: @id,
      label: "Add glossary definition and audio link columns",
      init: &init/1,
      process_row: &process_row/3
    }
  end

  def init(%JobParams{step_state: step_state} = params) do
    # get all the resource columns
    all_resource_cols = Helpers.get_resource_cols(params)

    # add three glossary columns after each learner id column
    params = Enum.reduce(all_resource_cols, params, fn {resource, resource_cols}, acc ->
      {learner_id_col, _index} = resource_cols[@learner_id]
      acc
        |> Helpers.add_output_column(glossary_audio_link_col(resource), :after, learner_id_col)
        |> Helpers.add_output_column(glossary_audio_definitions_col(resource), :after, learner_id_col)
        |> Helpers.add_output_column(glossary_text_definitions_col(resource), :after, learner_id_col)
    end)

    step_state = Map.put(step_state, @id, all_resource_cols)
    %{params | step_state: step_state}
  end

  # header row
  def process_row(%JobParams{step_state: step_state}, row, _data_row? = false) do
    # copy headers to new columns
    all_resource_cols = Map.get(step_state, @id)
    Enum.reduce(all_resource_cols, row, fn {resource, resource_cols}, {input, output} ->
      {_learner_id_col, index} = resource_cols[@learner_id]
      output = output
        |> Map.put(glossary_audio_link_col(resource), input[index])
        |> Map.put(glossary_audio_definitions_col(resource), input[index])
        |> Map.put(glossary_text_definitions_col(resource), input[index])
      {input, output}
    end)
  end

  # data rows
  def process_row(params = %JobParams{mode: mode, step_state: step_state, portal_url: portal_url}, row, _data_row? = true) do
    all_resource_cols = Map.get(step_state, @id)

    Enum.reduce(all_resource_cols, row, fn {resource, resource_cols}, {input, output} ->
      remote_endpoint = get_resource_col(input, resource_cols, @remote_endpoint)
      resource_url = get_resource_col(input, resource_cols, @resource_url)
      offering_id = get_resource_col(input, resource_cols, @offering_id)
      student_id = Helpers.get_input_value(params, input, "student_id")
      class_id = Helpers.get_input_value(params, input, "class_id")

      portal_uri = URI.parse(remote_endpoint)
      firebase_app = case portal_uri.host do
        "learn.concord.org" -> @prod_firebase_app
        "ngss-assessment.portal.concord.org" -> @prod_firebase_app
        _ -> @staging_firebase_app
      end

      output = case get_glossary_data(mode, remote_endpoint, resource_url) do
        {:ok, source, key, word_definitions, audio_definitions} ->
          audio_link_opts = [
            auth_domain: portal_url, # authenticate with the portal the report server is authenticated to
            firebase_app: firebase_app,
            source: source,
            portal_url: "#{portal_uri.scheme}://#{portal_uri.host}", # portal url of resource
            class_id: class_id,
            offering_id: offering_id,
            student_id: student_id,
            key: key
          ]
          output
            |> Map.put(glossary_audio_link_col(resource), get_audio_link(audio_definitions, audio_link_opts))
            |> Map.put(glossary_audio_definitions_col(resource), get_audio_definitions(audio_definitions))
            |> Map.put(glossary_text_definitions_col(resource), get_word_definitions(word_definitions))
        _ ->
          output
      end

      {input, output}
    end)
  end

  defp get_glossary_data(mode, remote_endpoint, resource_url) do
    source = URI.parse(resource_url).host
    with {:ok, plugin_states} <- ReportService.get_plugin_states(mode, source, remote_endpoint),
         {:ok, {key, plugin_state}} <- get_first_glossary_plugin_key_and_state(plugin_states),
         {:ok, {word_definitions, audio_definitions}} <- parse_plugin_state(plugin_state) do
      {:ok, source, key, word_definitions, audio_definitions}
    else
      {:error, error} ->
        Logger.error(error)
        {:error, error}
    end
  end

  defp glossary_text_definitions_col(resource), do: "#{resource}_glossary_text_definitions"
  defp glossary_audio_definitions_col(resource), do: "#{resource}_glossary_audio_definitions"
  defp glossary_audio_link_col(resource), do: "#{resource}_glossary_audio_link"

  defp get_first_glossary_plugin_key_and_state(plugin_states) do
    first_plugin_state = Enum.find(plugin_states, fn {_k, v} ->
      is_map(v) && Map.has_key?(v, "definitions") && is_map(v["definitions"])
    end)
    if first_plugin_state != nil do
      {:ok, first_plugin_state}
    else
      {:error, "No glossary plugin state found"}
    end
  end

  defp parse_plugin_state(%{"definitions" => all_definitions}) when is_map(all_definitions) do
    {all_word_definitions, all_audio_definitions} = Enum.reduce(all_definitions, {%{}, []}, fn ({word, definitions}, {word_definitions, audio_definitions}) ->
        non_audio_definitions = Enum.filter(definitions, fn definition ->
          !String.starts_with?(definition, "recordingData://")
        end) |> Enum.reverse()
        audio_definitions = if length(non_audio_definitions) < length(definitions) do
          [word | audio_definitions]
        else
          audio_definitions
        end
        |> Enum.sort()
        {Map.put(word_definitions, word, non_audio_definitions), audio_definitions}
      end)
    all_word_definitions = all_word_definitions
      |> Enum.filter(fn {_k, word_definitions} -> length(word_definitions) > 0 end)
    {:ok, {all_word_definitions, all_audio_definitions}}
  end
  defp parse_plugin_state(_) do
    {:ok, %{}, []}
  end

  defp get_audio_link(audio_definitions, _opts ) when length(audio_definitions) < 1, do: ""
  defp get_audio_link(_audio_definitions, opts), do: PortalReport.glossary_audio_link(opts)

  defp get_word_definitions(word_definitions) when map_size(word_definitions) == 0, do: ""
  defp get_word_definitions(word_definitions) do
    word_definitions
    |> Enum.map(fn {word, definitions} ->
      quoted_definitions = definitions
        |> Enum.map(&("\"#{&1}\""))
        |> Enum.join("; ")
      "#{word}: #{quoted_definitions}"
    end)
    |> Enum.join("\n")
  end

  defp get_audio_definitions(audio_definitions), do: Enum.join(audio_definitions, " ")

  defp get_resource_col(input, resource_cols, column_name) do
    {_col, index} = resource_cols[column_name]
    input[index]
  end

end
