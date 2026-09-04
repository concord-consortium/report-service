defmodule ReportServer.Reports.AthenaFailureTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.{AthenaFailure, Report, Tree}

  @athena_slugs ~w(student-actions student-actions-with-metadata student-answers
                   student-assignment-usage teacher-actions)

  # S3 reports its own throttling as "SlowDown", so a realistic throttling reason carries both the
  # Athena code and the token the generic slowdown entry matches on.
  @throttling_reason "HIVE_S3_THROTTLING: Amazon S3 error: Please reduce your request rate. " <>
                       "(Service: Amazon S3; Status Code: 503; Error Code: SlowDown; Request ID: A1B2C3D4)"

  @observed_reasons [
    "HIVE_EXCEEDED_PARTITION_LIMIT: too many",
    "CONSTRAINT_VIOLATION: injected column",
    @throttling_reason,
    "Query timeout: exhausted resources",
    "Slowdown"
  ]

  @slowdown_text "Your query was delayed due to high traffic in AWS Athena. Please try again in a few moments. This is a temporary issue caused by heavy usage."

  defp report(form_options), do: %Report{slug: "test-report", form_options: form_options}
  defp with_app_filter, do: report(enable_hide_names: true, enable_app_filter: true)
  defp without_app_filter, do: report(enable_hide_names: true)

  describe "truncate/1" do
    test "bounds an over-ceiling reason and marks it" do
      truncated = AthenaFailure.truncate(String.duplicate("x", 70_000))

      assert byte_size(truncated) <= AthenaFailure.max_reason_bytes()
      assert String.ends_with?(truncated, " ... (truncated)")
    end

    test "bounds a multi-byte reason by bytes and leaves valid UTF-8" do
      reason = String.duplicate("é", 40_000)
      assert byte_size(reason) > AthenaFailure.max_reason_bytes()

      truncated = AthenaFailure.truncate(reason)

      assert String.valid?(truncated)
      assert byte_size(truncated) <= AthenaFailure.max_reason_bytes()
    end

    test "leaves a reason under the limit byte-identical and unmarked" do
      reason =
        "CONSTRAINT_VIOLATION: " <>
          String.duplicate(
            "s3://report-service-output/partitions/application=activity-player/",
            5
          )

      assert byte_size(reason) < AthenaFailure.max_reason_bytes()
      assert AthenaFailure.truncate(reason) == reason
      refute AthenaFailure.truncate(reason) =~ "truncated"
    end

    test "passes nil through" do
      assert AthenaFailure.truncate(nil) == nil
    end
  end

  describe "guidance_for/2 suggestions" do
    test "each observed reason maps to its suggestion when no application filter is offered" do
      report = without_app_filter()

      assert AthenaFailure.guidance_for(report, "HIVE_EXCEEDED_PARTITION_LIMIT: too many") ==
               "This query covers too many Athena partitions. Narrow it with a date range and run it again."

      assert AthenaFailure.guidance_for(report, "CONSTRAINT_VIOLATION: injected column") ==
               "This query covers too many Athena partitions. Narrow it with a date range and run it again."

      assert AthenaFailure.guidance_for(report, @throttling_reason) ==
               "AWS throttled this query. Narrowing it with a date range will help, and running it outside peak hours will too."

      assert AthenaFailure.guidance_for(report, "Query timeout: exhausted resources") ==
               "This query ran out of time. Narrow it with a date range and consider running it outside peak hours."

      assert AthenaFailure.guidance_for(report, "Slowdown") == @slowdown_text
    end

    test "each observed reason maps to its suggestion when an application filter is offered" do
      report = with_app_filter()

      assert AthenaFailure.guidance_for(report, "HIVE_EXCEEDED_PARTITION_LIMIT: too many") ==
               "This query covers too many Athena partitions. Narrow it with a date range or one or more applications and run it again."

      assert AthenaFailure.guidance_for(report, "CONSTRAINT_VIOLATION: injected column") ==
               "This query covers too many Athena partitions. Narrow it with a date range or one or more applications and run it again."

      assert AthenaFailure.guidance_for(report, @throttling_reason) ==
               "AWS throttled this query. Narrowing it with a date range or one or more applications will help, and running it outside peak hours will too."

      assert AthenaFailure.guidance_for(report, "Query timeout: exhausted resources") ==
               "This query ran out of time. Narrow it with a date range or one or more applications and consider running it outside peak hours."

      assert AthenaFailure.guidance_for(report, "Slowdown") == @slowdown_text
    end

    test "the five reasons yield four distinct suggestions, the partition pair sharing one" do
      for report <- [with_app_filter(), without_app_filter()] do
        suggestions = Enum.map(@observed_reasons, &AthenaFailure.guidance_for(report, &1))

        refute Enum.any?(suggestions, &is_nil/1)
        assert Enum.at(suggestions, 0) == Enum.at(suggestions, 1)
        assert length(Enum.uniq(suggestions)) == 4
      end
    end

    test "an unrecognized reason gets no suggestion rather than a generic one" do
      assert AthenaFailure.guidance_for(without_app_filter(), "HIVE_MYSTERY: something else") ==
               nil
    end

    test "a nil reason gets no suggestion" do
      assert AthenaFailure.guidance_for(without_app_filter(), nil) == nil
    end
  end

  describe "guidance_for/2 application filter clause" do
    test "no suggestion mentions an application when the report does not offer the filter" do
      report = without_app_filter()

      for reason <- @observed_reasons do
        refute AthenaFailure.guidance_for(report, reason) =~ "application"
      end
    end

    test "the narrowing suggestions mention applications when the report offers the filter" do
      report = with_app_filter()

      for reason <- @observed_reasons -- ["Slowdown"] do
        assert AthenaFailure.guidance_for(report, reason) =~ "one or more applications"
      end
    end

    test "no Athena report in the tree that lacks the filter yields advice mentioning one" do
      reports = Enum.map(@athena_slugs, &Tree.find_report/1)

      for {slug, report} <- Enum.zip(@athena_slugs, reports) do
        assert match?(%Report{}, report), "no report in the tree for #{slug}"
      end

      exercised =
        for report <- reports, not AthenaFailure.offers_app_filter?(report) do
          refute AthenaFailure.guidance_for(report, "Query timeout: x") =~ "application"
          report.slug
        end

      assert exercised != []
    end

    test "offers_app_filter? reads the option and defaults to false" do
      assert AthenaFailure.offers_app_filter?(with_app_filter())
      refute AthenaFailure.offers_app_filter?(without_app_filter())
      refute AthenaFailure.offers_app_filter?(%Report{slug: "bare"})
      refute AthenaFailure.offers_app_filter?(nil)
    end
  end

  describe "guidance_for/2 matching hazards" do
    test "a reason carrying both the throttling code and SlowDown gets the throttling advice" do
      assert @throttling_reason =~ "HIVE_S3_THROTTLING"
      assert @throttling_reason =~ "SlowDown"

      advice = AthenaFailure.guidance_for(without_app_filter(), @throttling_reason)

      assert advice =~ "AWS throttled this query"
      refute advice == @slowdown_text
    end

    test "the slowdown entry fires whatever the casing" do
      for reason <- ["Slowdown", "SlowDown", "SLOWDOWN", "Athena returned SlowDown"] do
        assert AthenaFailure.guidance_for(without_app_filter(), reason) == @slowdown_text
      end
    end

    test "every pattern is lowercase, so it can match a downcased reason" do
      for app_filter? <- [true, false] do
        patterns = Enum.map(AthenaFailure.guidance(app_filter?), &elem(&1, 0))
        assert length(patterns) == 5

        for pattern <- patterns do
          assert pattern == String.downcase(pattern)
        end
      end
    end

    test "the slowdown advice never suggests narrowing" do
      for report <- [with_app_filter(), without_app_filter()] do
        advice = AthenaFailure.guidance_for(report, "Slowdown")

        assert advice == @slowdown_text
        refute advice =~ "date range"
        refute advice =~ "application"
      end
    end
  end
end
