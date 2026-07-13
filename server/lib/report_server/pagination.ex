defmodule ReportServer.Pagination do
  import Ecto.Query, warn: false

  alias ReportServer.Repo

  @per_page 25

  def per_page(), do: @per_page

  def paginate(query, page, per_page \\ @per_page) do
    total_count =
      query
      |> exclude(:order_by)
      |> exclude(:preload)
      |> Repo.aggregate(:count)

    total_pages = max(Float.ceil(total_count / per_page) |> trunc(), 1)
    page = page |> normalize_page() |> min(total_pages)

    items =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    %{items: items, page: page, per_page: per_page, total_pages: total_pages, total_count: total_count}
  end

  def normalize_page(page) when is_integer(page) and page >= 1, do: page
  def normalize_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end
  def normalize_page(_), do: 1
end
