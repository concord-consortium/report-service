# A top-level JSON array stored in a MySQL `json` column. type/0 is :map so MyXQL's loader prepends
# json_decode; dump returns a plain list which MyXQL JSON-encodes on the wire. A bare {:array, _} would
# not be json-decoded on load. Used for ExportScratch.endpoint_set and data_access_log.endpoint_set.
defmodule ReportServer.Types.EctoJsonArray do
  use Ecto.Type

  def type, do: :map

  def cast(list) when is_list(list), do: {:ok, list}
  def cast(_), do: :error

  def load(list) when is_list(list), do: {:ok, list}
  def load(_), do: :error

  def dump(list) when is_list(list), do: {:ok, list}
  def dump(_), do: :error
end
