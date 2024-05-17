defmodule ReportServer.PostProcessing.Steps.TranscribeAudio do
  require Logger

  alias ReportServerWeb.Aws
  alias ReportServerWeb.TokenService
  alias ReportServer.PostProcessing.{JobParams, Step, Output}
  alias ReportServer.PostProcessing.Steps.Helpers

  @id "transcribe_audio"

  def step do
    %Step{
      id: @id,
      label: "Add audio transcription column for open response answers",
      init: &init/1,
      process_row: &process_row/2
    }
  end

  def init(%JobParams{step_state: step_state} = params) do
    text_cols = Helpers.get_text_cols(params)

    params = Enum.reduce(text_cols, params, fn {text_col, _index}, acc ->
      acc
        |> Helpers.add_output_column(audio_transcription_result_col(text_col), :after, text_col)
        |> Helpers.add_output_column(audio_transcription_status_col(text_col), :after, text_col)
    end)

    step_state = Map.put(step_state, @id, text_cols)
    %{params | step_state: step_state}
  end

  def process_row(%JobParams{mode: mode, step_state: step_state}, row) do
    text_cols = Map.get(step_state, @id)
    Enum.reduce(text_cols, row, fn {text_col, _index}, {input, output} ->
      output = case transcribe_audio(mode, output, text_col) do
        {:ok, transcription} ->
          output
          |> Map.put(audio_transcription_status_col(text_col), "transcribed")
          |> Map.put(audio_transcription_result_col(text_col), transcription)
        {:error, error} ->
          # this is special cases as a student may not have provided an answer yet so it really isn't an error
          if error != "no answer to transcribe" do
            Logger.error("Error transcribing audio: #{error}")
          end
          output
          |> Map.put(audio_transcription_status_col(text_col), error)
          |> Map.put(audio_transcription_result_col(text_col), "")
      end
      {input, output}
    end)
  end

  defp audio_transcription_status_col(text_col), do: "#{text_col}_transcription_status"
  defp audio_transcription_result_col(text_col), do: "#{text_col}_transcription_result"

  defp transcribe_audio(mode, output, text_col) do
    with {:ok, answer} <- Helpers.get_answer(mode, output, text_col),
         {:ok, %{ interactive_state: interactive_state }} <- Helpers.parse_report_state(answer["report_state"]),
         {:ok, audio_file} <- get_audio_file(interactive_state),
         {:ok, audio_path} <- get_audio_path(answer, audio_file),
         {:ok, audio_s3_url} <- get_audio_s3_url(audio_path),
         {:ok, id, status} <- get_or_create_transcription_job(audio_s3_url),
         {:ok, transcription} <- get_transcription(id, status) do
      {:ok, transcription}
    else
      {:error, "answer not found"} ->
        {:error, "no answer to transcribe"}

      {:error, error} ->
        Logger.error("Error transcribing audio: #{error}")
        {:error, error}
    end
  end

  defp get_audio_file(interactive_state) do
    if interactive_state["audioFile"] != nil do
      {:ok, interactive_state["audioFile"]}
    else
      {:error, "no audio file"}
    end
  end

  defp get_audio_path(%{"attachments" => attachments}, audio_file) do
    attachment = attachments[audio_file]
    if attachment != nil && attachment["publicPath"] != nil do
      {:ok, attachment["publicPath"]}
    else
      {:error, "no audio path"}
    end
  end
  defp get_audio_path(_answer, _audio_file) do
    {:error, "no audio path"}
  end

  defp get_audio_s3_url(audio_path) do
    {:ok, "s3://#{TokenService.get_private_bucket()}/#{audio_path}"}
  end

  defp get_or_create_transcription_job(audio_s3_url) do
    id = :crypto.hash(:sha, audio_s3_url) |> Base.encode16()

    case Aws.get_transcription_job(id) do
      {:ok, status} ->
        {:ok, id, status}
      _error ->
        case Aws.start_transcription_job(id, audio_s3_url) do
          {:ok, status} ->
            {:ok, id, status}
          {:error, error} ->
            Logger.error("Error creating transcription job: #{error}")
            {:error, error}
        end
    end
  end

  defp get_transcription(id, :completed) do
    s3_url = Output.get_transcripts_url("#{id}.json")
    with {:ok, contents} <- Aws.get_file_contents("prod", s3_url), # prod here as we get the file contents in demo mode also
         {:ok, json} <- Jason.decode(contents),
         {:ok, transcript} <- get_transcript(json) do
        {:ok, transcript}
    else
      {:error, error} ->
        Logger.error("Error getting transcription: #{error}")
        {:error, error}
    end
  end

  defp get_transcription(id, _status) do
    case Aws.get_transcription_job(id) do
      {:ok, :completed} ->
        get_transcription(id, :completed)

      {:ok, status} ->
        # poll job until completed
        Process.send_after(self(), :call_get_transcription_job, 1000)
        receive do
          :call_get_transcription_job -> get_transcription(id, status)
        end

      {:error, error} ->
        Logger.error("Error getting transcription job: #{error}")
        {:error, error}
    end
  end

  defp get_transcript(%{"results" => %{"transcripts" => [%{"transcript" => transcript} | _]}}) do
    {:ok, transcript}
  end
  defp get_transcript(_) do
    {:error, "Unable to get transcript"}
  end
end
