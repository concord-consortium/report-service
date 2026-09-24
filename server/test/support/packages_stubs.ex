defmodule ReportServer.PackagesPortalStub do
  @moduledoc """
  Test double for the catalog's portal reads, configured as `:packages, :portal` in test.exs.
  Each answer is set per test with `set/1`, as a value or a function of the call's arguments,
  and is read from the application environment so a `Task` sees it too.
  """
  def set(answers), do: Application.put_env(:report_server, __MODULE__, Map.merge(defaults(), answers))
  def reset, do: Application.delete_env(:report_server, __MODULE__)

  def get_allowed_project_ids(user, _opts), do: answer(:allowed_project_ids, [user])

  defp defaults do
    %{allowed_project_ids: :none}
  end

  defp answer(key, args) do
    case Map.fetch!(Application.get_env(:report_server, __MODULE__, defaults()), key) do
      fun when is_function(fun) -> apply(fun, args)
      value -> value
    end
  end
end

defmodule ReportServer.PackagesMemoryStore do
  @moduledoc """
  Test double for the package store, configured as `:packages, :store` in test.exs. It records
  every put and can be told to fail, or to raise as a database error inside the publish would.
  """
  @behaviour ReportServer.Packages.Store

  def start, do: Agent.start_link(fn -> %{objects: %{}, fail: false} end, name: __MODULE__)
  def fail!, do: Agent.update(__MODULE__, &%{&1 | fail: true})
  def raise!(exception), do: Agent.update(__MODULE__, &%{&1 | fail: {:raise, exception}})
  def objects, do: Agent.get(__MODULE__, & &1.objects)

  @impl true
  def put(bucket, key, body) do
    Agent.get_and_update(__MODULE__, fn
      %{fail: true} = state -> {{:error, :injected}, state}
      %{fail: {:raise, _}} = state -> {state.fail, state}
      state -> {:ok, put_in(state, [:objects, {bucket, key}], body)}
    end)
    |> case do
      {:raise, exception} -> raise exception
      result -> result
    end
  end
end
