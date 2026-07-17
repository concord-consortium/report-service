defmodule ReportServerWeb.CustomComponentsTest do
  use ReportServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ReportServerWeb.CustomComponents
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Reports.{ReportFilter, ReportRun}

  test "renders never-used, an accessible caption, scoped headers, and an id-disambiguated revoke name" do
    t1 = %ApiToken{id: 41, label: nil, inserted_at: ~U[2026-07-01 14:22:00Z], last_used_at: nil}
    t2 = %ApiToken{id: 57, label: nil, inserted_at: ~U[2026-07-01 14:22:00Z], last_used_at: nil}

    html = render_component(&CustomComponents.token_table/1, tokens: [t1, t2], caption: "Your active CLI tokens")

    assert html =~ ~s(<caption class="sr-only">Your active CLI tokens</caption>)
    assert html =~ ~s(<th scope="col")
    assert html =~ "Never used"
    assert html =~ "aria-label=\"Revoke the unlabeled token (created 2026-07-01 14:22 UTC, never used, #41)\""
    assert html =~ "#57"
    assert html =~ ~s(data-confirm=)
  end

  test "a label with special characters is HTML-escaped in the confirm/accessible name" do
    t = %ApiToken{id: 42, label: "Doug's MacBook", inserted_at: ~U[2026-07-01 14:22:00Z], last_used_at: nil}

    html = render_component(&CustomComponents.token_table/1, tokens: [t], caption: "Your active CLI tokens")

    assert html =~ "the token labeled &#39;Doug&#39;s MacBook&#39;"
    assert html =~ "#42"
  end

  test "report_filter_values renders a nil report_filter as an empty filter table" do
    run = %ReportRun{report_filter: nil, report_filter_values: nil}

    html = render_component(&CustomComponents.report_filter_values/1, report_run: run)

    refute html =~ "Start Date"
    refute html =~ "Hide Names"
  end

  test "report_filter_values renders a populated report_filter" do
    run = %ReportRun{
      report_filter: %ReportFilter{filters: ["cohort"], start_date: "2024-01-01", hide_names: true},
      report_filter_values: %{"cohort" => %{"1" => "Cohort One"}}
    }

    html = render_component(&CustomComponents.report_filter_values/1, report_run: run)

    assert html =~ "Cohorts"
    assert html =~ "Cohort One"
    assert html =~ "Start Date"
    assert html =~ "2024-01-01"
    assert html =~ "Hide Names"
  end
end
