defmodule ReportServer.Clue do

  alias ReportServer.Reports.ReportUtils
  alias ReportServer.AthenaDB
  alias ReportServer.Accounts.User
  alias ReportServer.AthenaQueryPoller
  alias ReportServerWeb.Aws

  def is_clue_url?(url) do
    String.contains?(url, "collaborative-learning.concord.org")
  end

  def fetch_resource(url, learners, user = %User{}) do
    IO.inspect(url, label: "****** fetch resource url")
    IO.inspect(learners, label: "****** fetch resource learners")
    with {:ok, csv_path} <- query_for_text_tile_answers(url, learners, user),
         {:ok, data} <- read_text_tile_answer_csv(url, csv_path, learners) do
      {:ok, %{
        "type" => "clue",
        "url" => url,
        "name" => "Test Clue",
        "denormalized" => data.structure
      }}
    else
      error -> error
    end
  end

  defp query_for_text_tile_answers(_url, learners,  user = %User{}) do
    run_remote_endpoints = Enum.map(learners, fn learner -> learner[:run_remote_endpoint] end)
    sql = get_text_tile_answer_sql(run_remote_endpoints)
    with {:ok, query_id, _status} <- AthenaDB.query(sql, UUID.uuid4(), user),
          {:ok, path} <- AthenaQueryPoller.wait_for(query_id) do
        IO.inspect(path, label: "****** Path to CSV")
        {:ok, path}
    else
      error -> error
    end
  end

  defp get_text_tile_answer_sql(run_remote_endpoints) do
    """
    WITH last_changes AS (
      SELECT
        json_extract_scalar("log1"."parameters", '$.toolId') as tileId,
        MAX("log1"."time") AS time
      FROM "log_ingester_qa"."logs_by_time" log1
      WHERE "log1"."application" = 'CLUE'
        AND "log1"."event" = 'TEXT_TOOL_CHANGE'
        AND json_extract_scalar("log1"."parameters", '$.operation') = 'update'
        AND "log1"."run_remote_endpoint" in #{ReportUtils.string_list_to_single_quoted_in(run_remote_endpoints)}
      GROUP BY json_extract_scalar("log1"."parameters", '$.toolId')
    )

    SELECT
      "log"."username" AS username,
      json_extract_scalar("log"."parameters", '$.tileTitle') AS tile_title,
      json_extract_scalar("log"."parameters", '$.documentKey') AS document_key,
      json_extract_scalar("log"."parameters", '$.documentHistoryId') as document_history_id,
      json_extract_scalar("log"."parameters", '$.args[0].text') as text_value
    FROM "log_ingester_qa"."logs_by_time" log
      JOIN "last_changes" on (
        "last_changes"."tileId" = json_extract_scalar("log"."parameters", '$.toolId')
        AND "log"."time" = "last_changes"."time")
    WHERE "log"."application" = 'CLUE'
      AND "log"."event" = 'TEXT_TOOL_CHANGE'
      AND "log"."run_remote_endpoint" in #{ReportUtils.string_list_to_single_quoted_in(run_remote_endpoints)}
      AND json_extract_scalar("log"."parameters", '$.operation') = 'update'
      AND json_extract_scalar("log"."parameters", '$.tileTitle') is not null
      AND json_extract_scalar("log"."parameters", '$.tileTitle') != ''
      AND json_extract_scalar("log"."parameters", '$.tileTitle') != '<no title>'
      AND json_extract_scalar("log"."parameters", '$.tileTitle') not like 'Text %'
    """
  end

  defp get_parquet_file_path(url, username, resource_link_id) do
    bucket = System.get_env("ATHENA_REPORT_BUCKET")
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
    case Aws.get_file_stream(nil, csv_path) do
      {:ok, stream } -> parse_text_tile_answer_csv(url, stream, learners)
      error -> error
    end
  end

  defp parse_text_tile_answer_csv(url, stream, learners) do
    return_struct = %{
      structure: %{ questions: %{}, choices: %{}, question_order: []}, ## denormalized questions to return
      answers: %{}                                                     ## answer lists that will be written to parquet, keyed by username
    }

    result = stream
    |> CSV.decode(headers: true, validate_row_length: true)
    |> Enum.reduce(return_struct, fn {:ok, row}, row_acc ->
      IO.inspect(row, label: ">>>>>>> row")
      tile_title = row["tile_title"]
      question_id = String.downcase(tile_title)
      username = row["username"]
      [user_id, portal_site] = String.split(username, "@")

      updated_questions = Map.put(row_acc.structure.questions, question_id, %{
        :type => "clue_text_tile",
        :prompt => tile_title,
        :required => false
      })
      updated_question_order = [question_id | row_acc.structure.question_order]

      updated_answers = with text_field <- IO.inspect(row["text_value"], label: "*******text_value"),
            text_trimmed <- String.trim_leading(text_field, "\"") |> String.trim_trailing("\""),
            {:ok, json} <- IO.inspect(Jason.decode(text_trimmed), label: "*******text_value as json"),
            plain_text <- IO.inspect(extract_text(json), label: "*******text_value as plaintext"),
            {:ok, answer_json} <- Jason.encode(%{ "text" => plain_text, "url" => "TODO" }) do
        learner = Enum.find(learners, fn learner -> Integer.to_string(learner.user_id) == user_id end)
        answer_row = %{
          question_id: question_id,
          answer: answer_json,
          platform_user_id: user_id,
          resource_link_id: Integer.to_string(learner.offering_id),
          remote_endpoint: learner.run_remote_endpoint,
          id: row["id"], ## Using the ID of the event here, but it could be any arbitrary ID
          ## The following are constant and could be added later
          resource_url: url,
          platform_id: "https://#{portal_site}",
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
        user_answers = [ answer_row | Map.get(row_acc.answers, username, [])]
        Map.put(row_acc.answers, username, user_answers)
      else
        _ -> row_acc.answers
      end

      %{
        structure: %{
          questions: updated_questions,
          choices: %{},
          question_order: updated_question_order
        },
        answers: updated_answers
      }
    end)

    ## Loop over answers and write a parquet file for each username
    write_attempts = Enum.map(result.answers, fn {username, answerlist} ->
      IO.inspect({username, answerlist}, label: "****** Answerlist")
      resource_link_id = answerlist |> List.first() |> Map.get(:resource_link_id)
      with {:ok, path} <- get_parquet_file_path(url, username, resource_link_id) do
        answers_df = Explorer.DataFrame.new(answerlist)
        IO.inspect(path, label: "****** Trying to dump parquet file")
        IO.inspect(answers_df, label: "****** Dataframe for parquet")
        Explorer.DataFrame.to_parquet(answers_df, path)
      else
        _ -> IO.inspect({:error, "Failed to construct parquet file path"})
      end
    end)
    IO.inspect(write_attempts, label: "****** Write attempts")
    if (Enum.all?(write_attempts, fn result -> result == :ok end)) do
      {:ok, result}
    else
      IO.inspect({:error, "Failed to write parquet files"})
    end
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
