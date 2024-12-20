defmodule ReportServer.PortalReport do
  def get_url() do
    Application.get_env(:report_server, :portal_report)
    |> Keyword.get(:url, "https://portal-report.concord.org/branch/master/")
  end

  def glossary_audio_link(opts) do
    required_keys = [:auth_domain, :firebase_app, :source, :portal_url, :class_id, :offering_id, :student_id, :user_id, :key]

    if Enum.all?(required_keys, &Keyword.has_key?(opts, &1)) do
      auth_domain = Keyword.get(opts, :auth_domain)
      firebase_app = Keyword.get(opts, :firebase_app)
      source = Keyword.get(opts, :source)
      portal_url = Keyword.get(opts, :portal_url)
      class_id = Keyword.get(opts, :class_id)
      offering_id = Keyword.get(opts, :offering_id)
      student_id = Keyword.get(opts, :student_id)
      user_id = Keyword.get(opts, :user_id)
      key = Keyword.get(opts, :key)

      "#{get_url()}?glossary-audio=true&auth-domain=#{auth_domain}&firebase-app=#{firebase_app}&sourceKey=#{source}&portalUrl=#{portal_url}&classId=#{class_id}&studentId=#{student_id}&userId=#{user_id}&offeringId=#{offering_id}&pluginDataKey=#{key}"
    else
      ""
    end
  end

end
