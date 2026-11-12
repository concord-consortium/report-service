defmodule ReportServer.PostProcessing.JobLearnersDbTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  import ReportServer.JobFixtures

  alias ReportServer.PortalFixture
  alias ReportServer.PostProcessing.Job
  alias ReportServer.PostProcessing.Steps.ClueLinkToWork
  alias ReportServer.Reports.AllowedProjects

  defp endpoint(secure_key), do: "https://#{PortalFixture.server()}/dataservice/external_activity_data/#{secure_key}"

  defp row(secure_key) do
    parameters =
      %{"documentUid" => "999", "documentKey" => "-doc"}
      |> Jason.encode!()
      |> String.replace("\"", "\"\"")

    ~s("CLUE","1737574924","#{parameters}","#{endpoint(secure_key)}")
  end

  test "the admin-class test is read from the portal for a user with both roles" do
    input = ~s("application","time","parameters","run_remote_endpoint"\n) <> row("SECUREKEY123") <> "\n" <> row("SECUREKEY905") <> "\n"

    {job, query_result, overrides, get_output} =
      job_fixture(input, [ClueLinkToWork.step()], nil, %AllowedProjects{admin: [900], researcher: [902]})

    job = %{job | portal_url: PortalFixture.server()}
    Job.run(job, query_result, nil, overrides)

    [header | rows] = get_output.() |> String.split("\r\n", trim: true) |> Enum.map(&String.split(&1, ","))
    link = Enum.find_index(header, &(&1 == "link_to_work"))
    links = Map.new(rows, &{List.last(&1), Enum.at(&1, link)})

    assert links[endpoint("SECUREKEY123")] =~ "targetUserId=999"
    assert links[endpoint("SECUREKEY905")] == ""
  end
end
