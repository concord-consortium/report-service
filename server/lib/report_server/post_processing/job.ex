defmodule ReportServer.PostProcessing.Job do
  require Logger

  alias ElixirLS.LanguageServer.Providers.FoldingRange.Helpers
  alias ReportServerWeb.Aws
  alias ReportServer.Reports.ReportUtils
  alias ReportServer.PostProcessing.{JobParams, Output}
  alias ReportServer.PostProcessing.Steps.Helpers
  alias ReportServer.PortalDbs

  @derive {Jason.Encoder, only: [:id, :steps, :status, :result]}
  defstruct id: nil, query_id: nil, steps: [], status: :queued, ref: nil, result: nil, rows_processed: 0, started_at: 0, portal_url: nil

  defmodule JobOverrides do
    defstruct output: nil, get_input: nil, learners: nil
  end

  def run(job, query_result, job_server_pid, %JobOverrides{} = overrides \\ %JobOverrides{}) do
    with {:ok, preprocessed} <- preprocess_rows(job, query_result, overrides),
         {:ok, result} <- process_rows(job, query_result, job_server_pid, preprocessed, overrides) do
        {:ok, result}
    else
      {:error, error} -> {:error, error}
    end
  end

  def user_in_class_key(class_id, user_id) do
    "#{class_id}-#{user_id}"
  end

  def user_from_user_in_class_key(user_in_class_key) do
    user_in_class_key
    |> String.split("-")
    |> List.last()
  end

  # NOTE: if you add another preprocessing action here, this should be refactored to
  # put the preprocessing in each step instead of it all being here - the learner
  # preprocessing should be moved to a helper module that could be imported into the step
  # so that it could be used for multiple steps
  defp preprocess_rows(job, query_result, overrides) do
    preprocessed = %{
      learners: %{},         # map of run_remote_endpoint to offering_id and class_id
      primary_user_map: %{},
      merged_user_ids: %{},  # map of user_in_class_key (class_id + "-" + user_id) to a list of user_in_class_keys
      user_resources: %{},   # map of user_in_class_key to a map of user ids to a map of resource headers to values
    }

    actions = get_preprocess_actions(job)
    if length(actions) > 0 do
      # since reports can be huge we need to stream them and decode them line by line into rows
      case get_input_stream(query_result, overrides) do
        {:ok, stream } ->
          preprocessed = stream
          |> CSV.decode()

          # transform the csv stream into a steam of preprocessed rows with only the information needed for each preprocessing action
          |> Stream.transform(nil, fn {:ok, row}, row_acc ->
            if row_acc == nil do
              # this is the first line of the csv
              header_map = Helpers.get_header_map(row)
              rre_index = header_map["run_remote_endpoint"]
              user_id_index = header_map["user_id"]
              primary_user_id_index = header_map["primary_user_id"]
              class_id_index = header_map["class_id"]
              resource_header_map = Enum.reduce(header_map, %{}, fn {k,v}, acc ->
                if Regex.match?(~r/^res_\d+/, k) do
                  Map.put(acc, k, v)
                else
                  acc
                end
              end)
              {[new_preprocessed_row()], %{
                rre_index: rre_index,
                user_answers: %{},
                resource_header_map: resource_header_map,
                user_id_index: user_id_index,
                primary_user_id_index: primary_user_id_index,
                class_id_index: class_id_index,
              }}
            else
              input = row_to_input(row)
              new_row = Enum.reduce(actions, new_preprocessed_row(), fn action, new_row_acc ->
                cond do
                  action == :preprocess_learners && row_acc.rre_index != nil ->
                    %{new_row_acc | rre: input[row_acc.rre_index]}

                  action == :preprocess_gather_primary_user_info ->
                    primary_user_id = input[row_acc.primary_user_id_index] || ""
                    if String.length(primary_user_id) > 0 do
                      # we need to gather the primary user id and the resources for each row
                      resources = Enum.reduce(row_acc.resource_header_map, %{}, fn {k,v}, acc -> Map.put(acc, k, input[v]) end)
                      user_id = input[row_acc.user_id_index] || ""
                      class_id = input[row_acc.class_id_index] || ""
                      %{new_row_acc | user_id: user_id, class_id: class_id, primary_user_id: primary_user_id, resources: resources}
                    else
                      new_row_acc
                    end

                  # add future actions here...
                  true ->
                    new_row_acc
                end
              end)
              {[new_row], row_acc}
            end
          end)

          # this reducer is called each time a new row is emitted from the stream to gather the input needed for the preprocessing actions
          |> Enum.reduce(preprocessed, fn row, acc ->
            learners = if row.rre != nil, do: Map.put(acc.learners, row.rre, nil), else: acc.learners
            user_key = user_in_class_key(row.class_id, row.user_id)
            primary_user_key = if row.primary_user_id != nil do
              user_in_class_key(row.class_id, row.primary_user_id)
            else
              nil
            end
            merged_user_ids = if primary_user_key != nil && primary_user_key != user_key do
              Map.update(acc.merged_user_ids, primary_user_key, [user_key], fn user_ids ->
                user_ids ++ [user_key]
              end)
            else
              acc.merged_user_ids
            end
            user_resources = if primary_user_key != nil do
              Map.update(acc.user_resources, primary_user_key, Map.put(%{}, row.user_id, row.resources), fn user_resources ->
                Map.put(user_resources, row.user_id, row.resources)
              end)
            else
              acc.user_resources
            end
            primary_user_map = if primary_user_key != nil do
              Map.put(acc.primary_user_map, user_key, primary_user_key)
            else
              acc.primary_user_map
            end

            # add future accumulators here...
            %{acc | learners: learners, merged_user_ids: merged_user_ids, user_resources: user_resources, primary_user_map: primary_user_map}
          end)

          # finally we run the actions that need the preprocessed data
          preprocessed = Enum.reduce(actions, preprocessed, fn action, acc ->
            case action do
              :preprocess_learners ->
                run_remote_endpoints = Map.keys(acc.learners)
                %{acc | learners: get_learners(job, run_remote_endpoints, overrides)}

              :preprocess_gather_primary_user_info ->
                merged_user_ids = Enum.reduce(acc.merged_user_ids, %{}, fn {key, user_ids}, acc ->
                  Map.put(acc, key, Enum.uniq(user_ids))
                end)
                user_resources = Enum.reduce(acc.user_resources, %{}, fn {key, resources}, acc ->
                  Map.put(acc, key, resources)
                end) |> combine_user_resources()

                # reduce the primary user map to contain users with primary user ids such that
                # the primary user id is not also a user id in the map
                primary_user_map =
                  acc.primary_user_map
                  |> Enum.filter(fn {_key, value} -> not Map.has_key?(acc.primary_user_map, value) end)
                  |> Enum.reduce(%{}, fn {key, value}, acc ->
                    if Enum.any?(acc, fn {_k, v} -> v == value end) do
                      # primary user id already exists as a value, so ignore it
                      acc
                    else
                      # first time we see this primary user id, so we add it to the map
                      Map.put(acc, key, value)
                    end
                  end)

                %{acc | merged_user_ids: merged_user_ids, user_resources: user_resources, primary_user_map: primary_user_map}

              # add future actions here...
              _ -> acc
            end
          end)

          {:ok, preprocessed}

        {:error, error} ->
          Logger.error(error)
          {:error, error}
      end
    else
      {:ok, preprocessed}
    end
  end

  defp process_rows(job, query_result, job_server_pid, preprocessed, overrides) do
    # since reports can be huge we need to stream them and decode them line by line into rows
    case get_input_stream(query_result, overrides) do
      {:ok, stream } ->
        s3_url = stream
        |> CSV.decode()

        # this runs for each row of the csv, we transform the row with the steps and output the transformed row
        |> Stream.transform(nil, fn {:ok, row}, acc ->
          if acc == nil do
            # the accumulator is nil on the first line, with the headers which we parse and transform and
            # replace the line with the transformed header in the stream
            header_map = Helpers.get_header_map(row)
            params = %JobParams{
              input_header: row,
              input_header_map: header_map,
              output_header: row,
              output_header_map: header_map,
              rows_processed: 0,
              portal_url: job.portal_url,
              preprocessed: preprocessed
            }
            params = Enum.reduce(job.steps, params, fn step, acc -> step.init.(acc) end)
            {[params.output_header], increment_rows_processed(params, job_server_pid, job.id)}
          else
            output = run_steps(row, job.steps, acc)
            acc = increment_rows_processed(acc, job_server_pid, job.id)
            if length(output) == 0 do
              # this signals to the stream transformer to skip the row
              {[], acc}
            else
              {[output], acc}
            end
          end
        end)
        |> CSV.encode()
        |> put_output_stream(job, query_result, overrides)

        {:ok, s3_url}

      {:error, error} ->
        Logger.error(error)
        {:error, error}
    end
  end

  defp increment_rows_processed(params = %{rows_processed: rows_processed}, job_server_pid, job_id) do
    rows_processed = rows_processed + 1
    if job_server_pid != nil do
      send(job_server_pid, {:processed_row, job_id, rows_processed})
    end
    %{params | rows_processed: rows_processed}
  end

  defp run_steps(input_row, steps, params = %JobParams{input_header_map: input_header_map, output_header: output_header, output_header_map: output_header_map}) do
    input = row_to_input(input_row)
    output = Map.new(output_header_map, fn {k,_v} -> {k, input[input_header_map[k]] || ""} end)

    data_row? = is_data_row?(input_row)
    {_input, output} = Enum.reduce(steps, {input, output}, fn step, acc ->
      {_, step_output} = acc
      if step_output != false do
        step.process_row.(params, acc, data_row?)
      else
        acc
      end
    end)

    if map_size(output) == 0 do
      # skip output if the output is empty, which is how the step signals to skip the row
      []
    else
      Enum.reduce(output_header, [], fn k, acc ->
        [output[k] | acc]
      end)
      |> Enum.reverse()
    end
  end

  defp is_data_row?(row) do
    # true if the first cell has a integer in it
    case Integer.parse(Enum.at(row, 0, "")) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp get_input_stream(_query_result, %JobOverrides{get_input: get_input}) when not is_nil(get_input) do
    {:ok, get_input.()}
  end
  defp get_input_stream(query_result, _overrides) do
    Aws.get_file_stream(query_result.output_location)
  end

  defp put_output_stream(input_stream, job, query_result, overrides) do
    filename = "#{query_result.id}_job_#{job.id}.csv"
    if overrides.output do
      Enum.into(input_stream, overrides.output)
      "s3://streamed_output/jobs/#{filename}"
    else
      s3_url = Output.get_jobs_url(filename)
      contents = input_stream |> Enum.join()
      Aws.put_file_contents(s3_url, contents)
      s3_url
    end
  end

  defp get_preprocess_actions(job) do
    Enum.reduce(job.steps, MapSet.new(), fn step, acc ->
      cond do
        step.preprocess_learners ->
          MapSet.put(acc, :preprocess_learners)
        step.preprocess_gather_primary_user_info ->
          MapSet.put(acc, :preprocess_gather_primary_user_info)
        true ->
          acc
      end
    end)
    |> MapSet.to_list()
  end

  defp row_to_input(row) do
    Enum.with_index(row) |> Enum.map(fn {k,v} -> {v,k} end) |> Map.new()
  end

  defp new_preprocessed_row() do
    %{rre: nil, user_id: nil, class_id: nil, primary_user_id: nil, resources: %{}}
  end

  defp get_learners(_job_params, [], _overrides), do: %{}
  defp get_learners(_job_params, _run_remote_endpoints, %JobOverrides{learners: learners}) when not is_nil(learners), do: learners
  defp get_learners(%{portal_url: portal_url}, run_remote_endpoints, _overrides) do
    # extract the secure_key from the run_remote_endpoint
    secure_key_map = Enum.reduce(run_remote_endpoints, %{}, fn run_remote_endpoint, acc ->
      secure_key = run_remote_endpoint |> String.split("/") |> List.last()
      acc |> Map.put(secure_key, run_remote_endpoint)
    end)
    secure_keys = Map.keys(secure_key_map)

    # get the needed learner data from the portal
    sql = """
    SELECT pl.secure_key, pl.offering_id, pl.student_id, po.clazz_id FROM portal_learners pl
    JOIN portal_offerings po ON (po.id = pl.offering_id)
    where pl.secure_key in #{ReportUtils.string_list_to_single_quoted_in(secure_keys)}
    """

    # generate a map of run_remote_endpoint to offering_id and class_id
    case PortalDbs.query(portal_url, sql) do
      {:ok, result} ->
        Enum.reduce(result.rows, %{}, fn [secure_key, offering_id, student_id, class_id], acc ->
          run_remote_endpoint = secure_key_map[secure_key]
          acc |> Map.put(run_remote_endpoint, %{offering_id: offering_id, class_id: class_id, student_id: student_id})
        end)

      _ -> %{}
    end
  end

  # combine the user resources into a single map for each user
  # and merge the values into a single list with the list converted
  # to the value if the list has only one value
  defp combine_user_resources(user_resources) do
    Enum.into(user_resources, %{}, fn {user_id, entries} ->
      # merge the user id with the answers to form a tuple
      merged_entries =
        entries
        |> Enum.map(fn {outer_key, inner_map} ->
          Enum.reduce(inner_map, %{}, fn {k, v}, acc ->
            Map.put(acc, k, {outer_key, v})
          end)
        end)

      combined =
        merged_entries
        |> Enum.reduce(%{}, fn entry, acc ->
          Map.merge(acc, entry, fn _key, v1, v2 ->
            List.wrap(v1) ++ List.wrap(v2)
          end)
        end)
        |> Enum.map(fn {k, v} ->
          v_list = v |> List.wrap()
          values = Enum.map(v_list, fn {_, value} -> value end)
          v = if Enum.uniq(values) |> length == 1 do
            hd(v_list)
          else
            Enum.filter(v_list, fn {_, value} -> value != "" end)
          end
          {k, v}
        end)
        |> Enum.into(%{})

      {user_id, combined}
    end)
  end

end
