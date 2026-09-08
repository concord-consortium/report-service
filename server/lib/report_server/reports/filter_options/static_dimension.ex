defmodule ReportServer.Reports.FilterOptions.StaticDimension do
  @moduledoc """
  A dimension whose options are a fixed, server-defined vocabulary rather than portal data:
  no query, no project scoping, no cascading. The wire contract is identical to a portal
  dimension's, so no client branches on the kind.

  `options/1` takes the search text, `""` meaning everything, so a dimension owns how its own
  vocabulary narrows as well as what is in it. Implementors must test a label with
  `ReportServer.Reports.OptionLabel.matches?/2` rather than rolling their own comparison: the rule
  is substring, case-insensitive, over the label, matching what the portal dimensions get from
  `LIKE` under a `_ci` collation.
  """

  @callback options(search :: String.t()) :: [{id :: String.t(), label :: String.t()}]
  @callback enabled_for_report?(ReportServer.Reports.Report.t()) :: boolean()
end
