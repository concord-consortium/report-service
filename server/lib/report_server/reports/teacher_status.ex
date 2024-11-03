defmodule ReportServer.Reports.TeacherStatus do
  alias ReportServer.Reports.Report

  def new() do
    %Report{slug: "teacher-status", title: "Teacher Status", run: &__MODULE__.run/1}
  end

  def run(filters) do
    IO.inspect(filters, label: "Running #{__MODULE__}")
  end
end
