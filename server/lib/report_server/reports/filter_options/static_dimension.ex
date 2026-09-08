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

  **Ids must not be numeric strings.** It is the one place a client could tell the two kinds apart.
  A portal dimension breaks a label tie in SQL on `o.opt_id`, an integer column, so equal labels
  order numerically; a static dimension breaks it in `OptionLabel.sort_key/1`, which returns
  `{downcased_label, id}` with `id` a string, so equal labels order lexically. Sorting string ids
  numerically would be the wrong fix, since a later vocabulary could hold ids that merely look like
  numbers, so the constraint sits here instead.
  """

  @callback options(search :: String.t()) :: [{id :: String.t(), label :: String.t()}]
  @callback enabled_for_report?(ReportServer.Reports.Report.t()) :: boolean()
end
