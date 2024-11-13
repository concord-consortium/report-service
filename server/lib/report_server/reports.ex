defmodule ReportServer.Reports do
  @root_slug "new-reports"

  def get_root_slug(), do: @root_slug
  def get_root_path(), do: "/#{@root_slug}"
end
