defmodule ReportServer.Clue do

  require Logger

  ## The year partition is projected over this range in the Glue table.
  @projection_first_year 2014

  @other_tiles_key "other_tiles"

  @known_tracks ~w(A B C)

  alias ReportServer.Reports.ReportUtils
  alias ReportServer.AthenaDB
  alias ReportServer.Accounts.User
  alias ReportServer.AthenaQueryPoller
  alias ReportServerWeb.Aws
  alias ReportServer.Reports.Clue.HistoryLink

  def is_clue_url?(url) do
    String.contains?(url, "collaborative-learning.concord.org")
  end

  def fetch_resource(url, learners, user = %User{}) do
    with {:ok, csv_path} <- query_for_text_tile_answers(url, learners, user),
         {:ok, data} <- read_text_tile_answer_csv(url, csv_path, learners) do
      {:ok, %{
        "type" => "clue",
        "url" => url,
        "name" => resource_name(url),
        "denormalized" => data.structure
      }}
    else
      error -> error
    end
  end

  ## The rest of the app reaches AWS through these seams so a test can swap in a
  ## stub, as ResourceData and JobsFile do. AthenaQueryPoller routes its own
  ## AthenaDB call through the same seam, or stubbing here would intercept the
  ## query and not the poll loop.
  defp athena_db(), do: Application.get_env(:report_server, :athena_db, AthenaDB)
  defp aws_file_store(), do: Application.get_env(:report_server, :aws_file_store, Aws)

  @doc """
  A label for the CLUE activity, parsed from the runnable URL's unit and problem
  query parameters.

  The activity is already identified in the report output by res_N_resource_url,
  so the runnable URL is deliberately not a fallback: a name repeating it would
  add a redundant wide column and no information. The chain is the parsed label,
  then the unit alone, then a bare "CLUE".
  """
  def resource_name(runnable_url) do
    query = URI.decode_query(URI.parse(runnable_url).query || "")
    case {blank_to_nil(query["unit"]), blank_to_nil(query["problem"])} do
      {nil, _} -> "CLUE"
      {unit, nil} -> "CLUE #{unit}"
      {unit, problem} -> "CLUE #{unit}: Problem #{problem}"
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp query_for_text_tile_answers(_url, learners,  user = %User{}) do
    sql = answer_sql(learners)
    with {:ok, query_id, _status} <- athena_db().query(sql, UUID.uuid4(), user),
          {:ok, path} <- AthenaQueryPoller.wait_for(query_id) do
        {:ok, path}
    else
      error -> error
    end
  end

  @doc """
  The Athena log query behind the CLUE answers report, built from the learner
  maps fetch_resource/3 receives.

  Public so its shape can be asserted without running it: several of the
  decisions it encodes are invisible in the result set and checkable only here,
  such as which log table it reads and whether the learner predicates appear
  once or once per track.
  """
  def answer_sql(learners) do
    run_remote_endpoints =
      learners
      |> Enum.map(fn learner -> learner[:run_remote_endpoint] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    secure_keys = Enum.map(run_remote_endpoints, &(&1 |> String.split("/") |> List.last()))
    log_db_name = Application.get_env(:report_server, :athena)[:log_db_name]

    """
    WITH clue_logs AS (
      SELECT
        "log"."username" AS username,
        "log"."event" AS event,
        "log"."time" AS time,
        "log"."parameters" AS parameters,
        "log"."run_remote_endpoint" AS run_remote_endpoint
      FROM "#{log_db_name}"."logs_by_app_and_secure_key" log
      WHERE "log"."app" = 'CLUE'
        AND "log"."year" >= #{year_floor(learners)}
        AND "log"."secure_key" IN #{ReportUtils.string_list_to_single_quoted_in(secure_keys)}
        AND "log"."run_remote_endpoint" IN #{ReportUtils.string_list_to_single_quoted_in(run_remote_endpoints)}
        AND ("log"."event" = 'QUESTION_ANSWERS_CHANGE' OR regexp_like("log"."event", '_TOOL_CHANGE$'))
    ),

    #{track_c_cte()}

    #{track_c_select()}
    """
  end

  ## A learner cannot log before their learner record exists, so the earliest
  ## created_at year, less a year of slack, bounds the partitions worth scanning.
  ## Without a bound Athena enumerates every projected year for every learner,
  ## which costs wall time rather than bytes and so degrades invisibly. Only
  ## created_at bounds a learner from below, so one learner without it means the
  ## report cannot prune at all.
  defp year_floor(learners) do
    years = Enum.map(learners, &calendar_year(&1[:created_at]))

    if Enum.any?(years, &is_nil/1) do
      Logger.warning("CLUE answers: a learner has no created_at, scanning all projected years")
      @projection_first_year
    else
      max(Enum.min(years) - 1, @projection_first_year)
    end
  end

  defp calendar_year(%{year: year}), do: year
  defp calendar_year(value) when is_binary(value) do
    case Integer.parse(value) do
      {year, _} -> year
      :error -> nil
    end
  end
  defp calendar_year(_), do: nil

  defp track_c_cte() do
    """
    track_c AS (
      SELECT
        username,
        run_remote_endpoint,
        json_extract_scalar(parameters, '$.toolId') AS tool_id,
        json_extract_scalar(parameters, '$.tileTitle') AS tile_title,
        json_extract_scalar(parameters, '$.args[0].text') AS text_value,
        json_extract_scalar(parameters, '$.documentKey') AS document_key,
        json_extract_scalar(parameters, '$.documentHistoryId') AS document_history_id,
        ROW_NUMBER() OVER (
          PARTITION BY run_remote_endpoint,
                       COALESCE(json_extract_scalar(parameters, '$.toolId'),
                                json_extract_scalar(parameters, '$.tileId'))
          ORDER BY time DESC) AS rn
      FROM clue_logs
      WHERE event = 'TEXT_TOOL_CHANGE'
        AND json_extract_scalar(parameters, '$.operation') = 'update'
        AND json_extract_scalar(parameters, '$.tileTitle') IS NOT NULL
        AND json_extract_scalar(parameters, '$.tileTitle') != ''
        AND json_extract_scalar(parameters, '$.tileTitle') != '<no title>'
    )
    """
  end

  defp track_c_select() do
    """
    SELECT
      'C' AS track,
      username,
      run_remote_endpoint,
      CAST(NULL AS VARCHAR) AS question_id,
      CAST(NULL AS VARCHAR) AS answers,
      CAST(NULL AS VARCHAR) AS prompt,
      CAST(NULL AS VARCHAR) AS event,
      tool_id,
      tile_title,
      text_value,
      document_key,
      CAST(NULL AS VARCHAR) AS document_type,
      document_history_id
    FROM track_c
    WHERE rn = 1
    """
  end

  defp get_parquet_file_path(url, username, resource_link_id) do
    bucket = Application.get_env(:report_server, :athena)[:bucket]
    escaped_url = ReportUtils.escape_url_for_filename(url)
    # The 'username' field will be something like "user_id@portal_site".
    [user_id, portal_site] = String.split(username, "@")
    platform_id = ReportUtils.escape_url_for_filename("https://#{portal_site}")
    path = "s3://#{bucket}/partitioned-answers/#{escaped_url}/#{platform_id}/#{resource_link_id}/#{user_id}.parquet";
    FSS.S3.parse(path, config: get_s3_config())
  end

  defp get_s3_config() do
    [
      region: "us-east-1", ## should be an environment variable
      access_key_id: System.get_env("SERVER_ACCESS_KEY_ID"),
      secret_access_key: System.get_env("SERVER_SECRET_ACCESS_KEY"),
      bucket: System.get_env("ATHENA_REPORT_BUCKET")
    ]
  end

  ## Reads the CSV file in the given location
  ## Writes a parquet file with the answer data for each user in the dataset
  ## Returns the denormalized questions
  defp read_text_tile_answer_csv(url, csv_path, learners) do
    case aws_file_store().get_file_stream(csv_path) do
      {:ok, stream } -> parse_answer_csv(url, stream, learners)
      error -> error
    end
  end

  @doc """
  Parses the Athena CSV into the denormalized question structure and the answer
  rows, then writes the answer rows out.

  Public, and with the write injectable, because the structure is only half the
  output: fetch_resource/3 returns the structure alone, so assertions about the
  emitted answer rows are otherwise unobservable, and those are the ones
  guarding silent loss. Pass `write_answers: fn answers -> :ok end` to assert on
  the rows without an S3 write or credentials.

  Returns {:ok, %{structure: ..., answers: ...}}.
  """
  def parse_answer_csv(url, stream, learners, opts \\ []) do
    write_answers = Keyword.get(opts, :write_answers, &write_answer_parquet_files(url, &1))
    parse_text_tile_answer_csv(stream, learners, write_answers)
  end

  defp parse_text_tile_answer_csv(stream, learners, write_answers) do
    return_struct = %{
      structure: %{ questions: %{}, choices: %{}, question_order: []}, ## denormalized questions to return
      answers: %{}                                                     ## answer lists that will be written to parquet, keyed by username
    }

    learners_by_endpoint = Map.new(learners, &{&1.run_remote_endpoint, &1})

    result = stream
    |> CSV.decode(headers: true, validate_row_length: true)
    |> Enum.reduce(Map.merge(return_struct, %{unmatched: [], unknown_tracks: []}), &reduce_row(&1, learners_by_endpoint, &2))
    |> report_skipped()
    |> finalize()

    case write_answers.(result.answers) do
      :ok -> {:ok, result}
      error -> error
    end
  end

  defp reduce_row({:ok, row}, learners_by_endpoint, row_acc) do
    case {row["track"], Map.get(learners_by_endpoint, row["run_remote_endpoint"])} do
      {"C", learner} when not is_nil(learner) ->
        reduce_text_tile_row(row, learner, row_acc)

      {track, nil} when track in @known_tracks ->
        skip_row(row_acc, :unmatched, row["run_remote_endpoint"])

      {track, _learner} ->
        skip_row(row_acc, :unknown_tracks, track)
    end
  end
  defp reduce_row({:error, reason}, _learners_by_endpoint, row_acc) do
    Logger.error("CLUE answers: undecodable CSV row: #{inspect(reason)}")
    row_acc
  end

  defp skip_row(row_acc, cause, detail), do: Map.update!(row_acc, cause, &[detail | &1])

  ## One line per cause rather than one per row, so a systematic mismatch does
  ## not bury the log, with an example to start diagnosis from.
  defp report_skipped(result) do
    log_skipped(result.unmatched, "rows whose run_remote_endpoint matches no learner")
    log_skipped(result.unknown_tracks, "rows with an unrecognized track")
    result |> Map.delete(:unmatched) |> Map.delete(:unknown_tracks)
  end

  defp log_skipped([], _description), do: :ok
  defp log_skipped(details, description) do
    Logger.error("CLUE answers: skipped #{length(details)} #{description}, e.g. #{inspect(List.last(details))}")
  end

  defp reduce_text_tile_row(row, learner, row_acc) do
    tile_title = row["tile_title"]
    question_id = text_tile_key(tile_title)
    username = row["username"]
    [user_id, portal_site] = String.split(username, "@")
    portal_url = "https://#{portal_site}"

    structure =
      put_question(row_acc.structure, question_id, %{
        type: "clue_text_tile",
        prompt: tile_title,
        required: false
      })

    history_url = history_link(row, learner, portal_site, user_id)

    answers = with text_field <- row["text_value"],
          text_trimmed <- String.trim_leading(text_field, "\"") |> String.trim_trailing("\""),
          {:ok, json} <- Jason.decode(text_trimmed),
          plain_text <- extract_text(json),
          {:ok, answer_json} <- Jason.encode(%{ "text" => plain_text, "url" => history_url }) do
      add_answer_row(row_acc.answers, username, answer_row(question_id, answer_json, learner, user_id, portal_url, history_url))
    else
      _ -> row_acc.answers
    end

    %{row_acc | structure: structure, answers: answers}
  end

  ## `other_tiles` is Track B's synthetic key, and make_safe_id/1 maps titles such
  ## as "Other Tiles" onto it. Colliding would merge two column families under one
  ## map_agg key, which silently keeps one of them.
  defp text_tile_key(tile_title) do
    case make_safe_id(tile_title) do
      @other_tiles_key -> @other_tiles_key <> "_text"
      key -> key
    end
  end

  defp put_question(structure, question_id, question) do
    if Map.has_key?(structure.questions, question_id) do
      structure
    else
      %{structure |
        questions: Map.put(structure.questions, question_id, question),
        question_order: [question_id | structure.question_order]}
    end
  end

  defp add_answer_row(answers, username, answer_row) do
    Map.update(answers, username, [answer_row], &[answer_row | &1])
  end

  defp answer_row(question_id, answer_json, learner, user_id, portal_url, history_url) do
    %{
      question_id: question_id,
      answer: answer_json,
      platform_user_id: user_id,
      resource_link_id: Integer.to_string(learner.offering_id),
      remote_endpoint: learner.run_remote_endpoint,
      id: nil,
      resource_url: history_url,
      platform_id: portal_url,
      source_key: "collaborative-learning.concord.org",
      tool_id: "collaborative-learning.concord.org",
      version: "1",
      submitted: false,
      run_key: nil,
      context_id: nil,
      class_info_url: nil,
      type: nil,
      question_type: nil,
      tool_user_id: nil,
      created: nil
    }
  end

  ## CLUE emits "first" when a document had no history entry at log time, and
  ## omits the field entirely on some tile-change events. Neither resolves to a
  ## history position in CLUE, and passing them through opens the playback UI at
  ## a point it never navigated to, so the parameter is left off instead.
  defp history_link(row, learner, portal_site, user_id) do
    HistoryLink.format_link_to_work(%HistoryLink{
      portal_url: portal_site,
      offering_id: Integer.to_string(learner.offering_id),
      class_id: Integer.to_string(learner.class_id),
      document_key: row["document_key"],
      document_uid: user_id,
      maybe_document_history_id: usable_history_id(row["document_history_id"])})
  end

  defp usable_history_id(nil), do: nil
  defp usable_history_id("first"), do: nil
  defp usable_history_id(history_id) do
    case String.trim(history_id) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  ## CLUE answers have no natural order, so just sort alphabetically
  defp finalize(result) do
    Map.update!(result, :structure, fn structure ->
      Map.put(structure, :question_order, Enum.sort(structure.question_order))
    end)
  end

  ## The default writer: one parquet file per username, into the same
  ## partitioned-answers layout the AP path uses.
  defp write_answer_parquet_files(url, answers) do
    write_attempts = Enum.map(answers, fn {username, answerlist} ->
      resource_link_id = answerlist |> List.first() |> Map.get(:resource_link_id)
      with {:ok, path} <- get_parquet_file_path(url, username, resource_link_id) do
        answers_df = Explorer.DataFrame.new(answerlist)
        Explorer.DataFrame.to_parquet(answers_df, path)
      else
        _ -> {:error, "Failed to construct parquet file path"}
      end
    end)
    if (Enum.all?(write_attempts, fn result -> result == :ok end)) do
      :ok
    else
      {:error, "Failed to write parquet files"}
    end
  end

  ## Make arbitrary string into a legal SQL identifier.
  ## These may not start with a digit or contain most special characters.
  defp make_safe_id(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> String.replace(~r/^\d/, "q\\0")
  end

  def extract_text(%{"document" => %{"children" => nodes}}), do: extract_from_nodes(nodes) |> Enum.join(" ")
  def extract_text(_), do: ""

  defp extract_from_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.flat_map(fn
      %{"text" => text} -> [text]
      %{"children" => child_nodes} -> extract_from_nodes(child_nodes)
      _ -> []
    end)
  end
  defp extract_from_nodes(_), do: []

end
