defmodule ReportServer.Clue do

  alias ReportServer.Reports.ReportUtils

  def is_clue_url?(url) do
    String.contains?(url, "collaborative-learning.concord.org")
  end

  def fetch_resource(url, learners) do
    IO.inspect(url, label: "****** fetch resource url")
    IO.inspect(learners, label: "****** fetch resource learners")
    with {:ok, csv_path} <- query_for_text_tile_answers(url),
         {:ok, data} <- parse_text_tile_answer_csv(url, csv_path, learners) do
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

  defp query_for_text_tile_answers(_url) do
    # TODO
    # Should kick off Athena query to fetch resource
    # Wait for Athena query to complete
    # Return reference to the S3 CSV file
    {:ok, "TODO"}
  end

  defp get_parquet_file_path(url, username) do
    bucket = System.get_env("ATHENA_REPORT_BUCKET")
    escaped_url = ReportUtils.escape_url_for_filename(url)
    # The 'username' field will be something like "user_id@portal_site".
    [user_id, portal_site] = String.split(username, "@")
    platform_id = ReportUtils.escape_url_for_filename("https://#{portal_site}")
    resource_link_id = "588" ## offering id
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
  defp parse_text_tile_answer_csv(url, _csv_path, learners) do
    # TODO get stream from S3 rather than using this mock data
    # case Aws.get_file_stream(mode, query_result.output_location) do
    #   {:ok, stream } ->
    #     preprocessed = stream
    #     |> CSV.decode()...

    #     "GzbUjlUW67HRSUvjPEtAZ","266@learn.portal.staging.concord.org","pn1qe92Xkx_19YCP","4_5_Question1","-OK7YQig6OxOLf9F84zu","anntEAki_54lesjhGRaFO","{""text"":""{\""object\"":\""value\"",\""document\"":{\""children\"":[{\""type\"":\""paragraph\"",\""children\"":[{\""text\"":\""Question 1\"",\""bold\"":true}]},{\""type\"":\""paragraph\"",\""children\"":[{\""text\"":\""Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution. \""}]},{\""type\"":\""paragraph\"",\""children\"":[{\""text\"":\""I've pulled in question 1 and am answering it.\""}]}]}}""}"
    # "GzbUjlUW67HRSUvjPEtAZ","266@learn.portal.staging.concord.org","pn1qe92Xkx_19YCP","4_5_Question1","-OK7YQig6OxOLf9F84zu","anntEAki_54lesjhGRaFO","{\""text\"":\""Question 1\""}"

    sample_csv_data = """
    "id","username","tile_title","documentKey","documentHistoryId","text_value"
    "GzbUjlUW67HRSUvjPEtAZ","266@learn.portal.staging.concord.org","4_5_Question1","-OK7YQig6OxOLf9F84zu","anntEAki_54lesjhGRaFO","{\""object\"":\""value\"",\""document\"":{\""children\"":[{\""type\"":\""paragraph\"",\""children\"":[{\""text\"":\""Question 1\"",\""bold\"":true}]},{\""type\"":\""paragraph\"",\""children\"":[{\""text\"":\""Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution. \""}]},{\""type\"":\""paragraph\"",\""children\"":[{\""text\"":\""I've pulled in question 1 and am answering it.\""}]}]}}"
    """
    {:ok, io} = StringIO.open(sample_csv_data)
    stream = IO.stream(io, :line)

    return_struct = %{
      structure: %{ questions: %{}, choices: %{}, question_order: []}, ## denormalized questions to return
      answers: %{}                                                      ## answers that will be written to parquet, keyed by username
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
            {:ok, json} <- IO.inspect(Jason.decode(text_field), label: "*******text_value as json"),
            plain_text <- IO.inspect(extract_text(json), label: "*******text_value as plaintext"),
            {:ok, answer_json} <- Jason.encode(%{ "text" => plain_text, url => "TODO" }) do
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
      with {:ok, path} <- get_parquet_file_path(url, username) do
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
