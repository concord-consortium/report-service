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

  def run(mode, job, query_result, job_server_pid) do
    with {:ok, preprocessed} <- preprocess_rows(mode, job, query_result, job_server_pid),
         {:ok, result} <- process_rows(mode, job, query_result, job_server_pid, preprocessed) do
        {:ok, result}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp preprocess_rows(mode, job, query_result, job_server_pid) do
    preprocessed = %{
      learners: %{}
    }

    actions = get_preprocess_actions(job)
    if length(actions) > 0 do
      case Aws.get_file_stream(mode, query_result.output_location) do
        {:ok, stream } ->
          preprocessed = stream
          |> CSV.decode()
          |> Stream.transform(nil, fn {:ok, row}, row_acc ->
            if row_acc == nil do
              # the accumulator is nil on the first line
              header_map = Helpers.get_header_map(row)
              rre_index = header_map["run_remote_endpoint"]
              # add other index lookups here for future actions
              {[new_preprocessed_row()], %{rre_index: rre_index}}
            else
              input = row_to_input(row)
              new_row = Enum.reduce(actions, new_preprocessed_row(), fn action, new_row_acc ->
                cond do
                  action == :preprocess_learners && row_acc.rre_index != nil ->
                    %{new_row_acc | rre: input[row_acc.rre_index]}

                  # add future actions here...
                end
              end)
              {[new_row], row_acc}
            end
          end)
          |> Enum.reduce(preprocessed, fn row, acc ->
            learners = if row.rre != nil, do: Map.put(acc.learners, row.rre, nil), else: acc.learners
            # add future accumulators here...
            %{acc | learners: learners}
          end)

          preprocessed = Enum.reduce(actions, preprocessed, fn action, acc ->
            case action do
              :preprocess_learners ->
                run_remote_endpoints = Map.keys(acc.learners)
                %{acc | learners: get_learners(job, run_remote_endpoints)}
              # add future actions here...
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

  defp process_rows(mode, job, query_result, job_server_pid, preprocessed) do
    case Aws.get_file_stream(mode, query_result.output_location) do
      {:ok, stream } ->
        result = stream
        |> CSV.decode()
        |> Stream.transform(nil, fn {:ok, row}, acc ->
          if acc == nil do
            # the accumulator is nil on the first line, with the headers which we parse and transform and
            # replace the line with the transformed header in the stream
            header_map = Helpers.get_header_map(row)
            params = %JobParams{
              mode: mode,
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
            {[run_steps(row, job.steps, acc)], increment_rows_processed(acc, job_server_pid, job.id)}
          end
        end)
        |> CSV.encode()
        |> output_stream(mode, job, query_result.id)

        {:ok, result}

      {:error, error} ->
        Logger.error(error)
        {:error, error}
    end
  end

  defp increment_rows_processed(params = %{rows_processed: rows_processed}, job_server_pid, job_id) do
    rows_processed = rows_processed + 1
    send(job_server_pid, {:processed_row, job_id, rows_processed})
    %{params | rows_processed: rows_processed}
  end

  defp run_steps(input_row, steps, params = %JobParams{input_header_map: input_header_map, output_header: output_header, output_header_map: output_header_map}) do
    input = row_to_input(input_row)
    output = Map.new(output_header_map, fn {k,_v} -> {k, input[input_header_map[k]] || ""} end)

    data_row? = is_data_row?(input_row)
    {_input, output} = Enum.reduce(steps, {input, output}, fn step, acc ->
      step.process_row.(params, acc, data_row?)
    end)

    Enum.reduce(output_header, [], fn k, acc ->
      [output[k] | acc]
    end)
    |> Enum.reverse()
  end

  defp is_data_row?(row) do
    # true if the first cell has a integer in it
    case Integer.parse(Enum.at(row, 0, "")) do
      {_, ""} -> true
      _ -> false
    end
  end

  defp output_stream(stream, "demo", _job, _query_id) do
    stream
    |> Enum.join()
  end

  defp output_stream(stream, mode, job, query_id) do
    s3_url = Output.get_jobs_url("#{query_id}_job_#{job.id}.csv")
    contents = stream |> Enum.join()
    Aws.put_file_contents(mode, s3_url, contents)
    s3_url
  end

  defp get_preprocess_actions(job) do
    Enum.reduce(job.steps, MapSet.new(), fn step, acc ->
      if step.preprocess_learners do
        MapSet.put(acc, :preprocess_learners)
      else
        acc
      end
    end)
    |> MapSet.to_list()
  end

  defp row_to_input(row) do
    Enum.with_index(row) |> Enum.map(fn {k,v} -> {v,k} end) |> Map.new()
  end

  defp new_preprocessed_row() do
    %{rre: nil}
  end

  defp get_learners(%{portal_url: portal_url}, []), do: %{}
  defp get_learners(%{portal_url: portal_url}, run_remote_endpoints) do
    # extract the secure_key from the run_remote_endpoint
    secure_key_map = Enum.reduce(run_remote_endpoints, %{}, fn run_remote_endpoint, acc ->
      secure_key = run_remote_endpoint |> String.split("/") |> List.last()
      acc |> Map.put(secure_key, run_remote_endpoint)
    end)
    secure_keys = Map.keys(secure_key_map)

    # get the needed learner data from the portal
    sql = """
    SELECT pl.secure_key, pl.offering_id, po.clazz_id FROM portal_learners pl
    JOIN portal_offerings po ON (po.id = pl.offering_id)
    where pl.secure_key in #{ReportUtils.string_list_to_single_quoted_in(secure_keys)}
    """

    # generate a map of run_remote_endpoint to offering_id and class_id
    case PortalDbs.query(portal_url, sql) do
      {:ok, result} ->
        Enum.reduce(result.rows, %{}, fn [secure_key, offering_id, class_id], acc ->
          run_remote_endpoint = secure_key_map[secure_key]
          acc |> Map.put(run_remote_endpoint, %{offering_id: offering_id, class_id: class_id})
        end)

      _ -> %{}
    end
  end

end
