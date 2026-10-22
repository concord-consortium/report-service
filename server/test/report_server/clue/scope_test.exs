defmodule ReportServer.Clue.ScopeTest do
  use ExUnit.Case, async: true

  alias ReportServer.Clue
  alias ReportServer.Clue.Scope

  @hash_a String.duplicate("a", 48)
  @hash_b String.duplicate("b", 48)
  @clue "https://collaborative-learning.concord.org/branch/master/?unit=x"
  @lara "https://activity.concord.org/a"

  defp learner(user_id, class_id, offering_id, url \\ @clue),
    do: %{user_id: user_id, class_id: class_id, offering_id: offering_id, runnable_url: url}

  describe "Clue.writes_clue_documents?/1" do
    test "accepts CLUE's host, branch builds included, and the Dataflow 3.0 host, in any case" do
      assert Clue.writes_clue_documents?("https://collaborative-learning.concord.org/branch/master/?unit=x")
      assert Clue.writes_clue_documents?("HTTPS://Collaborative-Learning.Concord.Org/")
      assert Clue.writes_clue_documents?("http://collaborative-learning.concord.org/")
      assert Clue.writes_clue_documents?("https://dataflow-app.concord.org/")
    end

    test "refuses a lookalike host, another scheme, a host named only in the query, and non-URLs" do
      refute Clue.writes_clue_documents?("https://collaborative-learning.concord.org.example.com/")
      refute Clue.writes_clue_documents?("ftp://collaborative-learning.concord.org/")
      refute Clue.writes_clue_documents?("https://activity.concord.org/?x=collaborative-learning.concord.org")
      refute Clue.writes_clue_documents?(nil)
      refute Clue.writes_clue_documents?("")
    end

    test "differs from is_clue_url?/1 on a host named only in the query" do
      url = "https://activity.concord.org/?x=collaborative-learning.concord.org"
      assert Clue.is_clue_url?(url)
      refute Clue.writes_clue_documents?(url)
    end
  end

  describe "student_owners/2" do
    test "folds one student's learners in a class into one owner with each run offering" do
      learners = [learner(101, 601, 703), learner(101, 601, 701), learner(102, 601, 702)]

      owners = learners |> Scope.student_owners(%{601 => @hash_a}) |> Scope.order()

      assert owners == [
               %{"class_hash" => @hash_a, "uid" => "101", "kind" => "student", "portal_class_id" => 601, "offerings" => [701, 703]},
               %{"class_hash" => @hash_a, "uid" => "102", "kind" => "student", "portal_class_id" => 601, "offerings" => [702]}
             ]
    end

    test "keeps one owner per class for a student in two classes" do
      owners =
        [learner(101, 601, 701), learner(101, 602, 801)]
        |> Scope.student_owners(%{601 => @hash_a, 602 => @hash_b})
        |> Scope.order()

      assert Enum.map(owners, &{&1["class_hash"], &1["portal_class_id"], &1["offerings"]}) ==
               [{@hash_a, 601, [701]}, {@hash_b, 602, [801]}]
    end

    test "leaves out a learner whose class has no hash and a learner off a CLUE host" do
      learners = [learner(101, 601, 701), learner(102, 602, 702), learner(103, 601, 703, @lara)]

      assert [%{"uid" => "101"}] = Scope.student_owners(learners, %{601 => @hash_a})
    end

    test "accepts branch builds and the Dataflow 3.0 host" do
      learners = [
        learner(101, 601, 701, "https://collaborative-learning.concord.org/branch/dataflow/"),
        learner(102, 601, 702, "https://dataflow-app.concord.org/")
      ]

      assert ["101", "102"] = learners |> Scope.student_owners(%{601 => @hash_a}) |> Scope.order() |> Enum.map(& &1["uid"])
    end
  end

  describe "class_owners/1 and classes/1" do
    test "one class owner per class, with every student's run offerings" do
      students =
        [learner(101, 601, 701), learner(102, 601, 703), learner(103, 602, 801)]
        |> Scope.student_owners(%{601 => @hash_a, 602 => @hash_b})

      class_owners = students |> Scope.class_owners() |> Scope.order()

      assert class_owners == [
               %{"class_hash" => @hash_a, "uid" => "class_" <> @hash_a, "kind" => "class", "portal_class_id" => 601, "offerings" => [701, 703]},
               %{"class_hash" => @hash_b, "uid" => "class_" <> @hash_b, "kind" => "class", "portal_class_id" => 602, "offerings" => [801]}
             ]

      assert Scope.classes(class_owners) == [
               %{"class_hash" => @hash_a, "offerings" => [701, 703]},
               %{"class_hash" => @hash_b, "offerings" => [801]}
             ]
    end

    test "a class owner lists an offering its students share once, and no nil offering" do
      [class_owner] =
        [learner(101, 601, 701), learner(102, 601, 701), learner(103, 601, nil)]
        |> Scope.student_owners(%{601 => @hash_a})
        |> Scope.class_owners()

      assert class_owner["offerings"] == [701]
    end

    test "a class whose only learner is on a LARA URL has no student owner and so no class owner" do
      students = Scope.student_owners([learner(101, 601, 701, @lara)], %{601 => @hash_a})

      assert students == []
      assert Scope.class_owners(students) == []
    end
  end

  describe "group_owners/2" do
    test "a group is narrowed to the one offering of its answer row, in its class's portal class" do
      class_owners =
        [learner(101, 601, 701), learner(101, 601, 703), learner(102, 602, 801)]
        |> Scope.student_owners(%{601 => @hash_a, 602 => @hash_b})
        |> Scope.class_owners()

      groups = [
        %{"class_hash" => @hash_a, "uid" => "group_703_2", "offering" => 703},
        %{"class_hash" => @hash_b, "uid" => "group_801_1", "offering" => 801}
      ]

      assert Scope.group_owners(groups, class_owners) == [
               %{"class_hash" => @hash_a, "uid" => "group_703_2", "kind" => "group", "portal_class_id" => 601, "offerings" => [703]},
               %{"class_hash" => @hash_b, "uid" => "group_801_1", "kind" => "group", "portal_class_id" => 602, "offerings" => [801]}
             ]
    end
  end

  describe "order/1 and key/1" do
    test "orders by class hash, then owner id" do
      owners = [
        %{"class_hash" => @hash_b, "uid" => "101"},
        %{"class_hash" => @hash_a, "uid" => "group_1_1"},
        %{"class_hash" => @hash_a, "uid" => "102"}
      ]

      assert Enum.map(Scope.order(owners), &{&1["class_hash"], &1["uid"]}) ==
               [{@hash_a, "102"}, {@hash_a, "group_1_1"}, {@hash_b, "101"}]
    end

    test "an owner's audit key names its class hash and uid" do
      assert Scope.key(%{"class_hash" => @hash_a, "uid" => "101"}) == "clue:#{@hash_a}:101"
    end
  end
end
