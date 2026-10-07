defmodule ReportServer.Packages.Store do
  @moduledoc """
  Where package archives are written: each portal's runner bucket, under `packages/`, with the
  dedicated credential that may write only there. Configured as `:packages, :buckets` (portal
  server to bucket) and `:packages, :store` (the implementation, `S3Store` outside tests).
  """

  @callback put(bucket :: String.t(), key :: String.t(), body :: binary()) :: :ok | {:error, term()}

  @spec bucket_for(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def bucket_for(portal_server) do
    case Map.fetch(config(:buckets, %{}), portal_server) do
      {:ok, bucket} -> {:ok, bucket}
      :error -> {:error, "publishing is not configured for #{portal_server}"}
    end
  end

  def put(bucket, key, body), do: config(:store, __MODULE__.S3Store).put(bucket, key, body)

  defp config(key, default), do: Keyword.get(Application.get_env(:report_server, :packages, []), key, default)
end

defmodule ReportServer.Packages.Store.S3Store do
  @behaviour ReportServer.Packages.Store

  # Both puts run while the publish holds the package's row lock, so their worst case stays
  # under InnoDB's default 50-second lock wait as well as the publish transaction's timeout.
  @http_options [connect_timeout: 5_000, recv_timeout: 15_000]

  @impl true
  def put(bucket, key, body) do
    credentials = Keyword.fetch!(Application.fetch_env!(:report_server, :packages), :aws_credentials)
    client =
      AWS.Client.create(credentials[:access_key_id], credentials[:secret_access_key], "us-east-1")
      |> AWS.Client.put_http_client({AWS.HTTPClient.Hackney, @http_options})

    case AWS.S3.put_object(client, bucket, key, %{"Body" => body}) do
      {:ok, _, _} -> :ok
      error -> {:error, error}
    end
  end
end
