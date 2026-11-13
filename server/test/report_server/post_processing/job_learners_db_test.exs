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

  # every row names a classmate's document, so a link appears only in a class shown whole
  defp links(allowed, secure_keys) do
    input = ~s("application","time","parameters","run_remote_endpoint"\n) <> Enum.map_join(secure_keys, &(row(&1) <> "\n"))

    {job, query_result, overrides, get_output} = job_fixture(input, [ClueLinkToWork.step()], nil, allowed)

    job = %{job | portal_url: PortalFixture.server()}
    Job.run(job, query_result, nil, overrides)

    [header | rows] = get_output.() |> String.split("\r\n", trim: true) |> Enum.map(&String.split(&1, ","))
    link = Enum.find_index(header, &(&1 == "link_to_work"))
    Map.new(rows, &{List.last(&1), Enum.at(&1, link)})
  end

  test "the whole-class test is read from the portal for a user with both roles" do
    links = links(%AllowedProjects{admin: [900], researcher: [902]}, ["SECUREKEY123", "SECUREKEY905"])

    assert links[endpoint("SECUREKEY123")] =~ "targetUserId=999"
    assert links[endpoint("SECUREKEY905")] == ""
  end

  test "a researcher's class reached through a project with no forms is whole, and one through a project with forms is not" do
    assert links(%AllowedProjects{admin: [], researcher: [903]}, ["SECUREKEY908"])[endpoint("SECUREKEY908")] =~ "targetUserId=999"
    assert links(%AllowedProjects{admin: [], researcher: [902]}, ["SECUREKEY905"])[endpoint("SECUREKEY905")] == ""
  end
end
