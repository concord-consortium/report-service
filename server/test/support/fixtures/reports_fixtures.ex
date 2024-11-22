defmodule ReportServer.ReportsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `ReportServer.Reports` context.
  """

  @doc """
  Generate a report_run.
  """
  def report_run_fixture(attrs \\ %{}) do
    {:ok, report_run} =
      attrs
      |> Enum.into(%{
        report_filter: %{},
        report_filter_values: %{},
        report_slug: "some report_slug"
      })
      |> ReportServer.Reports.create_report_run()

    report_run
  end
end
