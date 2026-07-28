defmodule ReportServer.ClientClosedError do
  # Raised when Plug.Conn.chunk/2 returns {:error, :closed} because the client went away
  # mid-stream. Carries the (already-chunked) conn so the caller can return it quietly instead
  # of re-raising a MatchError as an error-level crash. A normal disconnect is not an error.
  defexception [:conn, message: "the client closed the connection mid-stream"]
end
