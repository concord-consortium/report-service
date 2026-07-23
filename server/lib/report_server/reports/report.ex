defmodule ReportServer.Reports.Report do
  # api_report_type is the report_type value the v1 API exposes on run metadata
  # (:answers | :usage | :log). The vocabulary is part of the API contract: every
  # Athena report must declare one, and additions are contract changes.
  defstruct type: nil, slug: nil, title: nil, subtitle: nil, include_filters: [], get_query: nil, parents: [], path: nil, tbd: false, form_options: [], api_report_type: nil

  defmacro __using__(opts) do
    quote do
      alias ReportServer.Accounts.User
      alias ReportServer.PortalDbs
      alias ReportServer.Reports.{Report, ReportFilter, ReportQuery}

      import ReportServer.Reports.ReportUtils

      @opts unquote(opts)

      def new(report = %Report{}) do
        %{report | get_query: &get_query/2, tbd: Keyword.get(@opts, :tbd, false), type: Keyword.get(@opts, :type, :portal), api_report_type: Keyword.get(@opts, :api_report_type) }
      end
    end
  end
end
