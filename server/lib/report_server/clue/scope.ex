defmodule ReportServer.Clue.Scope do
  @moduledoc """
  The scope owners of a CLUE document export: who holds the documents a run may read, each with the
  offerings that narrow them. Owners are plain string-keyed maps so they store in `export_scratch`
  unchanged and go to the CLUE function as they are.
  """

  @doc "Student owners from learner rows, given `%{class_id => class_hash}`. Learners off CLUE hosts or without a hash are left out."
  def student_owners(learners, hashes) do
    learners
    |> Enum.filter(&ReportServer.Clue.writes_clue_documents?(&1.runnable_url))
    |> Enum.filter(&Map.has_key?(hashes, &1.class_id))
    |> Enum.group_by(&{hashes[&1.class_id], &1.class_id, Integer.to_string(&1.user_id)}, & &1.offering_id)
    |> Enum.map(fn {{hash, class_id, uid}, offerings} ->
      owner(hash, uid, "student", class_id, offerings)
    end)
  end

  @doc "One class owner per class holding a student owner, narrowed by that class's run offerings."
  def class_owners(student_owners) do
    student_owners
    |> Enum.group_by(&{&1["class_hash"], &1["portal_class_id"]}, & &1["offerings"])
    |> Enum.map(fn {{hash, class_id}, offering_lists} ->
      owner(hash, "class_" <> hash, "class", class_id, List.flatten(offering_lists))
    end)
  end

  @doc "The `owners` request's classes: each class hash with its run offerings."
  def classes(class_owners), do: Enum.map(class_owners, &%{"class_hash" => &1["class_hash"], "offerings" => &1["offerings"]})

  @doc "Group owners from the function's `owners` answer; a group is narrowed to its own offering."
  def group_owners(groups, class_owners) do
    class_ids = Map.new(class_owners, &{&1["class_hash"], &1["portal_class_id"]})

    Enum.map(groups, fn %{"class_hash" => hash, "uid" => uid, "offering" => offering} ->
      owner(hash, uid, "group", Map.fetch!(class_ids, hash), [offering])
    end)
  end

  @doc "The frozen order: by class hash, then owner id."
  def order(owners), do: Enum.sort_by(owners, &{&1["class_hash"], &1["uid"]})

  @doc "The audit key of an owner."
  def key(%{"class_hash" => hash, "uid" => uid}), do: "clue:#{hash}:#{uid}"

  defp owner(hash, uid, kind, class_id, offerings) do
    %{"class_hash" => hash, "uid" => uid, "kind" => kind, "portal_class_id" => class_id,
      "offerings" => offerings |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()}
  end
end
