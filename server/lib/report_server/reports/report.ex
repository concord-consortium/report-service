defmodule ReportServer.Reports.Report do
  defstruct type: nil, slug: nil, title: nil, subtitle: nil, include_filters: [], get_query: nil, parents: [], path: nil, tbd: false, form_options: []

  defmacro __using__(opts) do
    quote do
      alias ReportServer.Accounts.User
      alias ReportServer.PortalDbs
      alias ReportServer.Reports.{Report, ReportFilter, ReportQuery}

      @opts unquote(opts)

      def new(report = %Report{}) do
        %{report | get_query: &get_query/2, tbd: Keyword.get(@opts, :tbd, false), type: Keyword.get(@opts, :type, :portal) }
      end

      defp list_to_in(list) do
        "(#{list |> Enum.map(&Integer.to_string/1) |> Enum.join(",")})"
      end

      defp have_filter?(filter_list), do: !Enum.empty?(filter_list)

      defp apply_start_date(where, start_date, table_name \\ "rl") do
        if String.length(start_date || "") > 0 do
          ["#{table_name}.last_run >= '#{start_date}'" | where]
        else
          where
        end
      end

      defp apply_end_date(where, end_date, table_name \\ "rl") do
        if String.length(end_date || "") > 0 do
          ["#{table_name}.last_run <= '#{end_date}'" | where]
        else
          where
        end
      end

      defp apply_where_filter(where, filter, additional_where) do
        if have_filter?(filter) do
          [additional_where | where]
        else
          where
        end
      end

    end
  end
end
