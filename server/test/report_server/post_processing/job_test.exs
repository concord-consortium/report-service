defmodule ReportServer.PostProcessing.JobTest do
  use ExUnit.Case, async: true

  import ReportServer.JobFixtures

  alias ReportServer.PostProcessing.Job
  alias ReportServer.PostProcessing.Steps.{ClueLinkToWork, MergeToPrimaryUser}

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

    test "runs the merge to primary user step successfully" do
      input = """
      "student_id","user_id","primary_user_id","student_name","username","school","class","class_id","permission_forms","teacher_user_ids","teacher_names","teacher_districts","teacher_states","teacher_emails","res_1_name","res_1_offering_id","res_1_learner_id","res_1_remote_endpoint","res_1_resource_url","res_1_last_run","res_1_total_num_questions","res_1_total_num_answers","res_1_total_percent_complete","res_1_num_required_questions","res_1_num_required_answers","res_1_q4_5_question1_text","res_1_q4_5_question1_url"
      "Correct answer",,,,,,,,,,,,,,,,,,,,,,,,,,
      "Prompt",,,,,,,,,,,,,,,,,,,,,,,,,"4_5_Question1","4_5_Question1"
      "136","279","266","Alias Neill","aneill","Concord Consortium","Aug2024","254","[]","88","Boris Goldowsky","","","bgoldowsky@concord.org","Test Clue","588","555","https://learn.portal.staging.concord.org/dataservice/external_activity_data/42519f74-e40a-43a6-a0cd-2d27e8c4132b","https://collaborative-learning.concord.org/?unit=m2s&problem=4.5","2025-03-10T21:03:59","1","1","100.0","0","0","Question 1 Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution.  YAY!!! {Write your answer here}","https://collaborative-learning.concord.org/?class=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fclasses%2F254&offering=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fofferings%2F588&researcher=true&reportType=offering&authDomain=https%3A%2F%2Flearn.portal.staging.concord.org%2F&resourceLinkId=588&targetUserId=279&studentDocument=-OL0rmfqiDsPlriZks-X&studentDocumentHistoryId=_n0gST0XUN0xt8JKoSUPZ"
      "123","266","266","Boris Neill","bneill","Concord Consortium","Aug2024","254","[]","88","Boris Goldowsky","","","bgoldowsky@concord.org","Test Clue","588","540","https://learn.portal.staging.concord.org/dataservice/external_activity_data/e59ef6bd-d7b9-4c51-9ff4-3ab47709f6d0","https://collaborative-learning.concord.org/?unit=m2s&problem=4.5","2025-03-10T15:43:18","1","1","100.0","0","0","Question 1 Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution.  I've pulled in question 1 and am answering it.","https://collaborative-learning.concord.org/?class=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fclasses%2F254&offering=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fofferings%2F588&researcher=true&reportType=offering&authDomain=https%3A%2F%2Flearn.portal.staging.concord.org%2F&resourceLinkId=588&targetUserId=266&studentDocument=-OK7YQig6OxOLf9F84zu&studentDocumentHistoryId=anntEAki_54lesjhGRaFO"
      "124","267","266","Fred Flintstone","fflintstone","Concord Consortium","Aug2024","254","[]","88","Boris Goldowsky","","","bgoldowsky@concord.org","Test Clue","588","541","https://learn.portal.staging.concord.org/dataservice/external_activity_data/e59ef6bd-d7b9-4c51-9ff4-3ab47709f6d1","https://collaborative-learning.concord.org/?unit=m2s&problem=4.5","2025-03-10T15:43:19","1","1","100.0","0","0","Question 1 Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution.  I don't know.","https://collaborative-learning.concord.org/?class=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fclasses%2F254&offering=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fofferings%2F588&researcher=true&reportType=offering&authDomain=https%3A%2F%2Flearn.portal.staging.concord.org%2F&resourceLinkId=588&targetUserId=266&studentDocument=-OK7YQig6OxOLf9F85zu&studentDocumentHistoryId=anntEAki_54lesjhGRaF1"
      "125","268","268","Wilma Flintstone","wflintstone","Concord Consortium","Aug2024","254","[]","88","Boris Goldowsky","","","bgoldowsky@concord.org","Test Clue","588","542","https://learn.portal.staging.concord.org/dataservice/external_activity_data/e59ef6bd-d7b9-4c51-9ff4-3ab47709f6d2","https://collaborative-learning.concord.org/?unit=m2s&problem=4.5","2025-03-10T15:43:20","1","1","100.0","0","0","Question 1 Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution.  I like eggs.","https://collaborative-learning.concord.org/?class=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fclasses%2F254&offering=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fofferings%2F588&researcher=true&reportType=offering&authDomain=https%3A%2F%2Flearn.portal.staging.concord.org%2F&resourceLinkId=588&targetUserId=266&studentDocument=-OK7YQig6OxOLf9F86zu&studentDocumentHistoryId=anntEAki_54lesjhGRaF2"
      """

      output = """
      student_id,user_id,primary_user_id,merged_user_ids,student_name,username,school,class,class_id,permission_forms,teacher_user_ids,teacher_names,teacher_districts,teacher_states,teacher_emails,res_1_name,res_1_offering_id,res_1_learner_id,res_1_remote_endpoint,res_1_resource_url,res_1_last_run,res_1_total_num_questions,res_1_total_num_answers,res_1_total_percent_complete,res_1_num_required_questions,res_1_num_required_answers,res_1_q4_5_question1_text,res_1_q4_5_question1_url\r
      Correct answer,,,,,,,,,,,,,,,,,,,,,,,,,,,\r
      Prompt,,,,,,,,,,,,,,,,,,,,,,,,,,4_5_Question1,4_5_Question1\r
      123,266,266,\"279,267\",Boris Neill,bneill,Concord Consortium,Aug2024,254,[],88,Boris Goldowsky,,,bgoldowsky@concord.org,Test Clue,588,\"555,540,541\",\"https://learn.portal.staging.concord.org/dataservice/external_activity_data/42519f74-e40a-43a6-a0cd-2d27e8c4132b,https://learn.portal.staging.concord.org/dataservice/external_activity_data/e59ef6bd-d7b9-4c51-9ff4-3ab47709f6d0,https://learn.portal.staging.concord.org/dataservice/external_activity_data/e59ef6bd-d7b9-4c51-9ff4-3ab47709f6d1\",https://collaborative-learning.concord.org/?unit=m2s&problem=4.5,\"2025-03-10T21:03:59,2025-03-10T15:43:18,2025-03-10T15:43:19\",1,1,100.0,0,0,\"Question 1 Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution.  YAY!!! {Write your answer here},Question 1 Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution.  I've pulled in question 1 and am answering it.,Question 1 Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution.  I don't know.\",\"https://collaborative-learning.concord.org/?class=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fclasses%2F254&offering=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fofferings%2F588&researcher=true&reportType=offering&authDomain=https%3A%2F%2Flearn.portal.staging.concord.org%2F&resourceLinkId=588&targetUserId=279&studentDocument=-OL0rmfqiDsPlriZks-X&studentDocumentHistoryId=_n0gST0XUN0xt8JKoSUPZ,https://collaborative-learning.concord.org/?class=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fclasses%2F254&offering=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fofferings%2F588&researcher=true&reportType=offering&authDomain=https%3A%2F%2Flearn.portal.staging.concord.org%2F&resourceLinkId=588&targetUserId=266&studentDocument=-OK7YQig6OxOLf9F84zu&studentDocumentHistoryId=anntEAki_54lesjhGRaFO,https://collaborative-learning.concord.org/?class=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fclasses%2F254&offering=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fofferings%2F588&researcher=true&reportType=offering&authDomain=https%3A%2F%2Flearn.portal.staging.concord.org%2F&resourceLinkId=588&targetUserId=266&studentDocument=-OK7YQig6OxOLf9F85zu&studentDocumentHistoryId=anntEAki_54lesjhGRaF1\"\r
      125,268,268,,Wilma Flintstone,wflintstone,Concord Consortium,Aug2024,254,[],88,Boris Goldowsky,,,bgoldowsky@concord.org,Test Clue,588,542,https://learn.portal.staging.concord.org/dataservice/external_activity_data/e59ef6bd-d7b9-4c51-9ff4-3ab47709f6d2,https://collaborative-learning.concord.org/?unit=m2s&problem=4.5,2025-03-10T15:43:20,1,1,100.0,0,0,Question 1 Write a few sentences telling the donor the volume of water needed for the tank and explain how you got your solution.  I like eggs.,https://collaborative-learning.concord.org/?class=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fclasses%2F254&offering=https%3A%2F%2Flearn.portal.staging.concord.org%2Fapi%2Fv1%2Fofferings%2F588&researcher=true&reportType=offering&authDomain=https%3A%2F%2Flearn.portal.staging.concord.org%2F&resourceLinkId=588&targetUserId=266&studentDocument=-OK7YQig6OxOLf9F86zu&studentDocumentHistoryId=anntEAki_54lesjhGRaF2\r
      """
      {job, query_result, overrides, get_output} = job_fixture(input, [MergeToPrimaryUser.step()])
      Job.run(job, query_result, nil, overrides)
      assert get_output.() == output
    end
  end
end
