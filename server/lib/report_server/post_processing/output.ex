defmodule ReportServer.PostProcessing.Output do
  def config() do
    output = Application.get_env(:report_server, :output)
    bucket = Keyword.get(output, :bucket, "report-server-output")
    jobs_folder = Keyword.get(output, :jobs_folder, "jobs")
    transcripts_folder = Keyword.get(output, :transcripts_folder, "transcripts")
    %{bucket: bucket, jobs_folder: jobs_folder, transcripts_folder: transcripts_folder}
  end

  def get_bucket() do
    %{bucket: bucket} = config()
    bucket
  end

  def get_jobs_url(filename) do
    %{bucket: bucket, jobs_folder: jobs_folder} = config()
    "s3://#{bucket}/#{jobs_folder}/#{filename}"
  end

  def get_transcripts_folder() do
    %{transcripts_folder: transcripts_folder} = config()
    "#{transcripts_folder}/"
  end

  def get_transcripts_url(filename) do
    %{bucket: bucket, transcripts_folder: transcripts_folder} = config()
    "s3://#{bucket}/#{transcripts_folder}/#{filename}"
  end

end
