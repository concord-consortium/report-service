defmodule ReportServer.PostProcessing.Steps.MergeToPrimaryUser do
  alias ReportServer.PostProcessing.Job
  alias ReportServer.PostProcessing.JobParams
  alias ReportServer.PostProcessing.Step
  alias ReportServer.PostProcessing.Steps.Helpers

  @id "merge_to_primary_user"
  @insert_after_col "primary_user_id"
  @merged_user_ids_col "merged_user_ids"

  def step do
    %Step{
      id: @id,
      label: "Merge user answers using \"primary_user_id\" column",
      init: &init/1,
      process_row: &process_row/3,
      preprocess_gather_primary_user_info: true
    }
  end

  def init(params) do
    Helpers.add_output_column(params, @merged_user_ids_col, :after, @insert_after_col)
  end

  # process each data row
  def process_row(%JobParams{preprocessed: preprocessed}, _row = {input, output = %{"class_id" => class_id, "user_id" => user_id}}, _data_row? = true) do
    user_key = Job.user_in_class_key(class_id, user_id)
    user_key = if Map.has_key?(preprocessed.user_resources, user_key) do
      user_key
    else
      # the user id isn't a primary user id, so we need to find the primary user key
      Map.get(preprocessed.primary_user_map, user_key)
    end
    if user_key do
      output = if Map.has_key?(preprocessed.merged_user_ids, user_key) do
        merged = preprocessed.merged_user_ids[user_key]
          |> Enum.map(&(Job.user_from_user_in_class_key(&1)))
          |> Enum.join(",")
        Map.put(output, @merged_user_ids_col, merged)
      else
        Map.put(output, @merged_user_ids_col, "")
      end

      output = Enum.reduce(preprocessed.user_resources[user_key], output, fn {key, value}, acc ->
        value = if is_list(value) do
          value
          |> Enum.map(fn {user_id, user_value} -> "#{user_id}: #{user_value}" end)
          |> Enum.join("\n")
        else
          {_user_id, user_value} = value
          user_value
        end
        Map.put(acc, key, value)
      end)

      {input, output}
    else
      {input, %{}}
    end
  end

  # ignore other rows
  def process_row(_job_params, row, _data_row?), do: row
end
