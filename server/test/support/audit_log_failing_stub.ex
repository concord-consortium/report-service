defmodule ReportServer.AuditLogFailingStub do
  def log_recent_logs_read(_user, _class_id, _since_ms, _endpoints), do: {:error, :stubbed}
end
