defmodule IthibatiInvites.InvitationEmail do
  @moduledoc "Application-owned invitation wording and adaptation to the existing Swoosh mailer."

  import Swoosh.Email

  alias IthibatiInvites.Mailer

  def content(url, _context) do
    escaped_url = url |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    {:ok,
     %{
       subject: "Your invitation",
       text: "Complete your registration with a passkey: #{url}",
       html: "<p><a href=\"#{escaped_url}\">Complete your registration with a passkey</a></p>"
     }}
  end

  def deliver(recipient, content) do
    new()
    |> to(recipient)
    |> from({"Ithibati invitations", "invites@example.test"})
    |> subject(content.subject)
    |> text_body(content.text)
    |> html_body(Map.get(content, :html))
    |> Mailer.deliver()
  end
end
