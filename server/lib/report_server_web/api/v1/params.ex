defmodule ReportServerWeb.Api.V1.Params do
  @default_limit 50
  @max_limit 200
  @max_bigint 9_223_372_036_854_775_807

  def parse_limit(params) do
    case Map.fetch(params, "limit") do
      :error ->
        {:ok, @default_limit}

      {:ok, value} when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} -> {:ok, n |> max(1) |> min(@max_limit)}
          _ -> {:error, "limit must be an integer"}
        end

      # a JSON body carries a number, where a query string can only carry a binary
      {:ok, value} when is_integer(value) ->
        {:ok, value |> max(1) |> min(@max_limit)}

      {:ok, _} ->
        {:error, "limit must be an integer"}
    end
  end

  def parse_page_token(params) do
    case Map.fetch(params, "page_token") do
      :error ->
        {:ok, nil}

      {:ok, token} when is_binary(token) ->
        with {:ok, decoded} <- Base.url_decode64(token, padding: false),
             {id, ""} when id > 0 and id <= @max_bigint <- Integer.parse(decoded) do
          {:ok, id}
        else
          _ -> {:error, "page_token is not valid"}
        end

      {:ok, _} ->
        {:error, "page_token is not valid"}
    end
  end

  def encode_page_token(id), do: Base.url_encode64(Integer.to_string(id), padding: false)

  @doc """
  Decodes a filter-option cursor, the `{label, id}` position of the last row of the previous page.

  Opaque by convention rather than signed: the dimension, the narrowing filter and the project
  scoping are all rebuilt from the request and the caller's role on every page, so a forged token
  can at worst start the caller at an odd position inside their own already-scoped result.
  """
  def parse_cursor(params) do
    case Map.fetch(params, "page_token") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, token} when is_binary(token) ->
        with {:ok, decoded} <- Base.url_decode64(token, padding: false),
             {:ok, [label, id]} when is_binary(label) and is_binary(id) <- Jason.decode(decoded) do
          {:ok, {label, id}}
        else
          _ -> {:error, "page_token is not valid"}
        end

      {:ok, _} ->
        {:error, "page_token is not valid"}
    end
  end

  def encode_cursor(nil), do: nil

  def encode_cursor({label, id}) do
    Base.url_encode64(Jason.encode!([label, id]), padding: false)
  end

  @doc "The largest id any API surface accepts, matching MySQL's signed BIGINT."
  def max_id, do: @max_bigint

  def parse_id(id_param) when is_binary(id_param) do
    with {id, ""} <- Integer.parse(id_param),
         true <- id > 0 and id <= @max_bigint do
      {:ok, id}
    else
      _ -> {:error, :not_found}
    end
  end
end
