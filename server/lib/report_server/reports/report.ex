defmodule ReportServer.Reports.Report do
  defstruct slug: nil, title: nil, subtitle: nil, run: nil, parents: [], path: nil

  defmacro __using__(_opts) do
    quote do
      alias ReportServer.PortalDbs
      alias ReportServer.Reports.Report

      def new(report = %Report{}), do: %{report | run: &run/1 }
    end
  end
end
