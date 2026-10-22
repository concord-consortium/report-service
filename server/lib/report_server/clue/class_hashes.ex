defmodule ReportServer.Clue.ClassHashes do
  @moduledoc "Portal class id to class hash, for the classes a CLUE export's learners are in."
  alias ReportServer.PortalDbs
  import ReportServer.Reports.ReportUtils, only: [list_to_in: 1]

  @doc "{:ok, %{class_id => class_hash}} for the ids whose class has a non-empty hash, or {:error, reason}."
  def fetch(_portal_server, []), do: {:ok, %{}}

  def fetch(portal_server, class_ids) do
    sql = "SELECT id, class_hash FROM portal_clazzes WHERE id IN #{list_to_in(class_ids)}"

    case PortalDbs.query(portal_server, sql) do
      {:ok, result} ->
        {:ok,
         result
         |> PortalDbs.map_columns_on_rows()
         |> Enum.filter(&(is_binary(&1.class_hash) and &1.class_hash != ""))
         |> Map.new(&{&1.id, &1.class_hash})}

      {:error, _} = err ->
        err
    end
  end
end
