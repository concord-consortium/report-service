defmodule ReportServer.Reports.Report do
  defstruct type: nil, slug: nil, title: nil, subtitle: nil, include_filters: [], get_query: nil, parents: [], path: nil, tbd: false, form_options: []

  defmacro __using__(opts) do
    quote do
      alias ReportServer.Accounts.User
      alias ReportServer.PortalDbs
      alias ReportServer.Reports.{Report, ReportFilter, ReportQuery}

      import ReportServer.Reports.ReportUtils

      @opts unquote(opts)

      def new(report = %Report{}) do
        %{report | get_query: &get_query/2, tbd: Keyword.get(@opts, :tbd, false), type: Keyword.get(@opts, :type, :portal) }
      end
    end
  end
end
