defmodule ReportServerWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  # the cc-data API contract uses a different error shape than the rest of the app, and it must
  # hold for raised exceptions too, not just explicitly rendered errors. The message is the
  # generic status phrase — never exception details.
  # the byte_size guard keeps binary_part/3 in-bounds for short paths (e.g. "/") — a raising
  # guard would already fall through, but the explicit length check makes that obvious
  def render(template, %{conn: %Plug.Conn{request_path: path}})
      when (byte_size(path) >= 5 and binary_part(path, 0, 5) == "/api/") or path == "/auth/cli/token" do
    status = template |> String.split(".") |> hd() |> String.to_integer()
    code = ReportServerWeb.Api.ErrorHelpers.code_for_status(status)
    %{error: code, message: Phoenix.Controller.status_message_from_template(template)}
  end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
