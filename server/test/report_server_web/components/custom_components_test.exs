defmodule ReportServerWeb.CustomComponentsTest do
  use ReportServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ReportServerWeb.CustomComponents
  alias ReportServer.Accounts.ApiToken
  alias ReportServer.Reports.{Report, ReportFilter, ReportRun, Tree}
  alias ReportServerWeb.Api.V1.ReportJSON

  test "renders never-used, an accessible caption, scoped headers, and an id-disambiguated revoke name" do
    t1 = %ApiToken{id: 41, label: nil, inserted_at: ~U[2026-07-01 14:22:00Z], last_used_at: nil}
    t2 = %ApiToken{id: 57, label: nil, inserted_at: ~U[2026-07-01 14:22:00Z], last_used_at: nil}

    html =
      render_component(&CustomComponents.token_table/1,
        tokens: [t1, t2],
        caption: "Your active CLI tokens"
      )

    assert html =~ ~s(<caption class="sr-only">Your active CLI tokens</caption>)
    assert html =~ ~s(<th scope="col")
    assert html =~ "Never used"

    assert html =~
             "aria-label=\"Revoke the unlabeled token (created 2026-07-01 14:22 UTC, never used, #41)\""

    assert html =~ "#57"
    assert html =~ ~s(data-confirm=)
  end

  test "a label with special characters is HTML-escaped in the confirm/accessible name" do
    t = %ApiToken{
      id: 42,
      label: "Doug's MacBook",
      inserted_at: ~U[2026-07-01 14:22:00Z],
      last_used_at: nil
    }

    html =
      render_component(&CustomComponents.token_table/1,
        tokens: [t],
        caption: "Your active CLI tokens"
      )

    assert html =~ "the token labeled &#39;Doug&#39;s MacBook&#39;"
    assert html =~ "#42"
  end

  test "report_filter_values renders a nil report_filter as an empty filter table" do
    run = %ReportRun{report_filter: nil, report_filter_values: nil}

    html = render_component(&CustomComponents.report_filter_values/1, report_run: run)

    refute html =~ "Start Date"
    refute html =~ "Hide Names"
    refute html =~ "Application"
  end

  test "report_filter_values renders a populated report_filter" do
    run = %ReportRun{
      report_filter: %ReportFilter{
        filters: ["cohort"],
        start_date: "2024-01-01",
        hide_names: true
      },
      report_filter_values: %{"cohort" => %{"1" => "Cohort One"}}
    }

    html = render_component(&CustomComponents.report_filter_values/1, report_run: run)

    assert html =~ "Cohorts"
    assert html =~ "Cohort One"
    assert html =~ "Start Date"
    assert html =~ "2024-01-01"
    assert html =~ "Hide Names"
  end

  test "report_filter_values renders the application when one was selected" do
    run = %ReportRun{report_filter: %ReportFilter{app: ["CLUE"]}, report_filter_values: nil}

    html = render_component(&CustomComponents.report_filter_values/1, report_run: run)

    assert html =~ "Application"
    assert html =~ "CLUE"
  end

  test "report_filter_values omits the application row for the empty string the form submits" do
    run = %ReportRun{report_filter: %ReportFilter{app: ""}, report_filter_values: nil}

    html = render_component(&CustomComponents.report_filter_values/1, report_run: run)

    refute html =~ "Application"
  end

  defp render_header(report, report_run) do
    render_component(&CustomComponents.report_header/1,
      report: report,
      report_run: report_run,
      row_count: 0,
      row_limit: 100
    )
  end

  defp athena_report(form_options \\ []),
    do: %Report{type: :athena, slug: "student-actions", form_options: form_options}

  defp athena_run(attrs), do: struct(%ReportRun{athena_query_state: "failed", athena_query_id: "qid-1"}, attrs)

  describe "report_header/1 for an Athena run" do
    test "names an application only when the report offers that filter" do
      run = athena_run(%{athena_query_error: "HIVE_EXCEEDED_PARTITION_LIMIT: too many"})

      refute render_header(athena_report(), run) =~ "one or more applications"
      assert render_header(athena_report(enable_app_filter: true), run) =~ "one or more applications"
    end

    test "the reason wraps, so an unbroken S3 url cannot overflow the page" do
      reason = "CONSTRAINT_VIOLATION: s3://" <> String.duplicate("a", 500)

      html = render_header(athena_report(), athena_run(%{athena_query_error: reason}))

      assert html =~ ~s(class="mt-1 font-mono text-sm break-words")
    end

    test "the live region wraps the block and is present before a reason arrives" do
      with_reason = render_header(athena_report(), athena_run(%{athena_query_error: "HIVE_MYSTERY: x"}))
      without_reason = render_header(athena_report(), athena_run(%{athena_query_error: nil}))

      assert with_reason =~ ~s(role="status")
      assert without_reason =~ ~s(role="status")
      refute without_reason =~ "Athena query id"
    end

    test "a succeeded run renders the download control rather than a failure block" do
      html = render_header(athena_report(), athena_run(%{athena_query_state: "succeeded"}))

      refute html =~ ~s(role="status")
      assert html =~ "Only CSV download is available"
    end

    test "the guidance it renders is the string the run JSON returns" do
      run =
        athena_run(%{
          report_slug: "student-actions",
          athena_query_error: "HIVE_EXCEEDED_PARTITION_LIMIT: too many",
          inserted_at: ~U[2026-09-10 12:00:00Z],
          updated_at: ~U[2026-09-10 12:00:00Z]
        })

      guidance = ReportJSON.show(run)[:athena_query_guidance]
      escaped = guidance |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      assert guidance =~ "one or more applications"
      assert render_header(Tree.find_report("student-actions"), run) =~ escaped
    end
  end
end
