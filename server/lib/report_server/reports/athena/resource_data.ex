defmodule ReportServer.Reports.Athena.ResourceData do

  require Logger

  alias ReportServer.Accounts.User
  alias ReportServer.{ReportService, AthenaDB, Clue}

  # NOTE: no struct definition but the shape of the reports data is a map whose keys are the same generated UUIDs
  # used as keys in the learner data and the values are maps with the runnable url, the resource and denormalized resource

  def fetch_and_upload(learner_data, user = %User{}) do
    with {:ok, resource_data} <- fetch(learner_data, user),
         {:ok, resource_data} <- upload(resource_data) do
      {:ok, resource_data}
    else
      error -> error
    end
  end

  def fetch(learner_data, user = %User{}) do
    resource_data = learner_data
      |> map_learner_data_to_runnable_data()
      |> Enum.map(fn value = %{runnable_url: runnable_url, query_id: query_id, learners: learners} ->

        with {:ok, resource} <- fetch_resource(runnable_url, learners, user),
             {:ok, denormalized} <- denormalize_resource(resource) do
          %{value | resource: resource, denormalized: denormalized}
        else
          {:error, _error} ->
            Logger.error("Error fetching resource for query_id: #{query_id}")
            # note: we don't want to stop the processing if a resource fails to fetch
            value
        end
      end)

    {:ok, resource_data}
  end

  def upload(resource_data) do
    resource_data
      |> Enum.each(fn %{query_id: query_id, denormalized: denormalized} ->
        if denormalized do
          path = "activity-structure/#{query_id}/#{query_id}-structure.json"
          contents = Jason.encode!(denormalized)
          Logger.info("Uploading resource to #{path}")
          AthenaDB.put_file_contents(path, contents)
        end
      end)

    {:ok, resource_data}
  end

  defp map_learner_data_to_runnable_data(learner_data) do
    learner_data
    |> Enum.map(fn %{runnable_url: runnable_url, query_id: query_id, learners: learners} ->
      %{runnable_url: runnable_url, query_id: query_id, learners: learners, resource: nil, denormalized: nil}
    end)
  end

  defp fetch_resource(nil, _learners, _user), do: {:ok, nil}
  defp fetch_resource(runnable_url, learners,  user = %User{}) do
    if Clue.is_clue_url?(runnable_url) do
      Clue.fetch_resource(runnable_url, learners, user)
    else
      {url, token} = ReportService.get_endpoint("resource")
      reported_url = extract_reported_url(runnable_url)
      source = URI.parse(reported_url).host

      ## API request that should return structure of the activity
      ReportService.get_request()
        |> Req.get(url: url,
          auth: {:bearer, token },
          params: [source: source, url: reported_url],
          retry: false,
          retry_log_level: false,
          debug: false
        )
        |> parse_resource_response()
    end
  end

  def parse_resource_response({:ok, %{body: %{"resource" => resource}}}) do
    {:ok, resource}
  end
  def parse_resource_response(_) do
    {:error, "Error parsing resource response"}
  end

  # Activity Player activities that have been imported from LARA have a resource url like
  # https://activity-player.concord.org/?activity=https%3A%2F%2Fauthoring.staging.concord.org%2Fapi%2Fv1%2Factivities%2F20753.json&firebase-app=report-service-dev
  # This function changes the above to https://authoring.staging.concord.org/activities/20753
  defp extract_reported_url(runnable_url) do
    query = URI.decode_query(URI.parse(runnable_url).query || "")
    if inner_url = extract_sequence_or_activity(query) do
      inner_url
      |> String.replace("http:", "https:")
      |> String.replace("api/v1/", "")
      |> String.replace(".json", "")
    else
      runnable_url
    end
  end

  defp extract_sequence_or_activity(%{"sequence" => sequence}), do: sequence
  defp extract_sequence_or_activity(%{"activity" => activity}), do: activity
  defp extract_sequence_or_activity(_), do: nil

  def denormalize_resource(nil), do: nil
  def denormalize_resource(resource) do
    denormalized = %{
      questions: %{},
      choices: %{},
      question_order: []
    }

    denormalized = case Map.get(resource, "type") do
      "clue" ->
        Map.get(resource, "denormalized")

      "activity" ->
        denormalize_activity(resource, denormalized)

      "sequence" ->
        Map.get(resource, "children", [])
        |> Enum.reduce(denormalized, fn activity, acc ->
          denormalize_activity(activity, acc)
        end)

      _ -> denormalized
    end

    denormalized = %{denormalized | question_order: Enum.reverse(denormalized.question_order)}

    {:ok, denormalized}
  end

  defp denormalize_activity(activity, denormalized) do
    Map.get(activity, "children", [])
    |> Enum.reduce(denormalized, fn section, acc ->
      Enum.reduce(Map.get(section, "children", []), acc, fn page, acc ->
        Enum.reduce(Map.get(page, "children", []), acc, fn question, acc ->
          denormalize_question(question, acc)
        end)
      end)
    end)
  end

  defp denormalize_question(question = %{"id" => id}, %{questions: questions, choices: choices, question_order: question_order} = denormalized) do
    prompt =
      case Map.get(question, "prompt") do
        prompt when is_binary(prompt) -> strip_html(prompt)
        prompt -> prompt || "(no prompt)"
      end

    prompt =
      if question_number = Map.get(question, "question_number") do
        "#{question_number}: #{prompt}"
      else
        prompt
      end

    question_type = Map.get(question, "type")
    question_data = %{
      prompt: prompt,
      required: Map.get(question, "required") || false,
      type: question_type
    }

    {questions, choices} =
      if question_type == "multiple_choice" do
        correct_answers =
          Map.get(question, "choices", [])
          |> Enum.filter(& Map.get(&1, "correct"))
          |> Enum.map(& Map.get(&1, "content"))
          |> Enum.join(", ")

        question_data =
          # note - camelCase is used here to match the existing data structure
          Map.put(question_data, :correctAnswer, "Correct answer(s): #{correct_answers}")

        choice_data =
          Enum.reduce(Map.get(question, "choices", []), %{}, fn choice, acc ->
            Map.put(acc, Map.get(choice, "id"), %{
              content: Map.get(choice, "content") || "",
              correct: Map.get(choice, "correct") || false
            })
          end)

        {Map.put(questions, id, question_data), Map.put(choices, id, choice_data)}
      else
        {Map.put(questions, id, question_data), choices}
      end

    %{denormalized | questions: questions, choices: choices, question_order: [id | question_order]}
  end

  defp strip_html(html) do
    case Floki.parse_fragment(html) do
      {:ok, parsed} ->
        Floki.text(parsed)
      _ ->
        html
    end
  end

end
