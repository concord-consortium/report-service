defmodule ReportServer.Reports.Athena.UploadTest do
  use ExUnit.Case, async: false

  alias ReportServer.AthenaDBStub
  alias ReportServer.Reports.Athena.{LearnerData, ResourceData}

  setup do
    on_exit(fn -> Application.delete_env(:report_server, :athena_db) end)
    :ok
  end

  defp stub_put(fun) do
    {:ok, pid} = AthenaDBStub.start(%{put_file_contents: fun})
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    Application.put_env(:report_server, :athena_db, AthenaDBStub)
  end

  @learner_data [%{query_id: "q1", learners: [%{run_remote_endpoint: "re-1"}]}]
  @resource_data [%{query_id: "q1", denormalized: %{"questions" => %{}}}]

  describe "LearnerData.upload/1" do
    test "returns the learner data when every put succeeds" do
      stub_put(fn _path, _contents -> {:ok, %{}, %{}} end)

      assert {:ok, @learner_data} == LearnerData.upload(@learner_data)
    end

    test "fails the upload when a put fails" do
      stub_put(fn _path, _contents -> {:error, :timeout} end)

      assert {:error, "Unable to upload the learner data for the report."} ==
               LearnerData.upload(@learner_data)
    end
  end

  describe "ResourceData.upload/1" do
    test "returns the resource data when every put succeeds" do
      stub_put(fn _path, _contents -> {:ok, %{}, %{}} end)

      assert {:ok, @resource_data} == ResourceData.upload(@resource_data)
    end

    test "fails the upload when a put fails" do
      stub_put(fn _path, _contents -> {:error, :timeout} end)

      assert {:error, "Unable to upload the resource data for the report."} ==
               ResourceData.upload(@resource_data)
    end

    test "skips entries with no denormalized resource without calling S3" do
      stub_put(fn _path, _contents -> raise "should not be called" end)
      resource_data = [%{query_id: "q1", denormalized: nil}]

      assert {:ok, ^resource_data} = ResourceData.upload(resource_data)
    end
  end
end
