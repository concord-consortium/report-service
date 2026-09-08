defmodule ReportServer.Reports.FilterOptions.AppDimension do
  @moduledoc "The applications the log tables are partitioned by, as a static filter dimension."

  @behaviour ReportServer.Reports.FilterOptions.StaticDimension

  alias ReportServer.Reports.AthenaFailure
  alias ReportServer.Reports.Athena.AthenaConfig

  # AthenaConfig.app_options/1 is {label, value} for Phoenix's options_for_select/2, which is the
  # reverse of this endpoint's {id, label}. Swapping here rather than keeping two lists is what
  # stops the form and the API disagreeing about what a value is called.
  @impl true
  def options(search) do
    Enum.map(AthenaConfig.app_options(search), fn {label, value} -> {value, label} end)
  end

  # `app` is not declared in include_filters; it is gated by the same form_options flag the web form
  # uses, so a report without an app partition rejects it here exactly as it hides the control there.
  @impl true
  def enabled_for_report?(report), do: AthenaFailure.offers_app_filter?(report)
end
