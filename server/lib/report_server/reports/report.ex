defmodule ReportServer.Reports.Report do
  defstruct slug: nil, title: nil, subtitle: nil, get_query: nil, parents: [], path: nil, tbd: false

  defmacro __using__(opts) do
    quote do
      alias ReportServer.PortalDbs
      alias ReportServer.Reports.{Report, ReportFilter, ReportQuery}

      @tbd Keyword.get(unquote(opts), :tbd, false)

      def new(report = %Report{}), do: %{report | get_query: &get_query/1, tbd: @tbd }

      defp list_to_in(list) do
        "(#{list |> Enum.map(&Integer.to_string/1) |> Enum.join(",")})"
      end

      defp have_filter?(filter_list), do: !Enum.empty?(filter_list)
    end
  end
end
