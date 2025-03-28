defmodule ReportServer.PostProcessing.JobTest do
  use ExUnit.Case, async: true

  import ReportServer.JobFixtures

  alias ReportServer.PostProcessing.Job
  alias ReportServer.PostProcessing.Steps.ClueLinkToWork

  describe "run/4" do
    test "runs a job with empty input and no steps successfully" do
      {job, query_result, overrides, get_output} = job_fixture()

      assert {:ok, s3_url} = Job.run(job, query_result, nil, overrides)
      assert s3_url == "s3://streamed_output/jobs/test_result_job_1.csv"
      assert get_output.() == ""
    end

    test "runs a job with input and no steps successfully" do
      input = "header1,header2\r\nvalue1,value2\r\nvalue3,value4\r\n"
      {job, query_result, overrides, get_output} = job_fixture(input)

      Job.run(job, query_result, nil, overrides)
      assert get_output.() == input
    end

    test "runs the CLUE link to work step successfully" do
      parameters = %{"documentUid" => "77701","documentKey" => "-OHEW9eC90nMQtAZHZhU","documentHistoryId" => "pQ99dWPLmCIvqTUWDr5NH"}
      |> Jason.encode!()
      |> String.replace("\"", "\"\"")
      link_to_work = "https://collaborative-learning.concord.org/?class=https%3A%2F%2Fportal.example.com%2Fapi%2Fv1%2Fclasses%2F1&offering=https%3A%2F%2Fportal.example.com%2Fapi%2Fv1%2Fofferings%2F1&researcher=true&reportType=offering&authDomain=https%3A%2F%2Fportal.example.com%2F&resourceLinkId=1&targetUserId=77701&studentDocument=-OHEW9eC90nMQtAZHZhU&studentDocumentHistoryId=pQ99dWPLmCIvqTUWDr5NH"

      input = """
      "id","session","username","application","activity","event","event_value","time","parameters","extras","run_remote_endpoint","timestamp"
      "NecBSeH5aIvdb2hjFZ32M","ace3d0ef-52ee-4997-a8c5-59cb8591dca1","77701@learn.concord.org","CLUE",,"TEXT_TOOL_CHANGE",,"1737574924","#{parameters}","{}","https://learn.concord.org/dataservice/external_activity_data/1cf47468-e793-4a54-b457-e4718a2a5dc0","1737574924741"
      """

      output = """
      id,session,username,application,activity,event,event_value,time,link_to_work,parameters,extras,run_remote_endpoint,timestamp\r
      NecBSeH5aIvdb2hjFZ32M,ace3d0ef-52ee-4997-a8c5-59cb8591dca1,77701@learn.concord.org,CLUE,,TEXT_TOOL_CHANGE,,1737574924,#{link_to_work},"#{parameters}",{},https://learn.concord.org/dataservice/external_activity_data/1cf47468-e793-4a54-b457-e4718a2a5dc0,1737574924741\r
      """
      learners = %{
        "https://learn.concord.org/dataservice/external_activity_data/1cf47468-e793-4a54-b457-e4718a2a5dc0" => %{offering_id: 1, class_id: 1}
      }
      {job, query_result, overrides, get_output} = job_fixture(input, [ClueLinkToWork.step()], learners)

      Job.run(job, query_result, nil, overrides)
      assert get_output.() == output
    end
  end
end
