defmodule Ithibati.InvitationMail do
  @moduledoc """
  Delivers existing invitation links through application-owned content and mailer functions.

  This module does not create invitations or change registration policy. Call it after the
  invitation's transaction commits. It refuses delivery inside the configured repo's transaction.
  For email identifiers, pass the invitation's normalized email as the recipient. Applications
  using usernames supply a separate delivery address. Construct the URL from trusted endpoint
  configuration, never from an untrusted request host.

  Configure `:invitation_mail` under `:ithibati`, or pass the complete options per call:

      config :ithibati, :invitation_mail,
        enabled: true,
        content: &MyApp.InvitationEmail.content/2,
        deliver: &MyApp.InvitationEmail.deliver/2

  The content function receives `(url, context)` and returns
  `{:ok, %{subject: subject, text: text}}`, optionally with `html: html`, or `{:error, reason}`.
  It may render application templates; Ithibati requires no template engine. The delivery
  function receives `(recipient, content)` and returns `{:ok, receipt}` or `{:error, reason}`.
  It owns the sender and adapts this map to the application's existing mailer.

  See [Invitations](invitations.md#email-delivery) for a mailer example, registration integration
  and retry semantics.
  """

  alias Ithibati.Config
  alias Ithibati.Schema.Identifier

  @doc "Returns whether invitation mail is explicitly enabled in the supplied or configured options."
  def enabled?(opts \\ configured()), do: Keyword.get(opts, :enabled, false) == true

  @doc """
  Renders and sends an existing invitation URL to a single mailbox.

  Options replace configuration rather than merging with it:

    * `:enabled` — opt-in boolean; defaults to `false`.
    * `:content` — a function of arity two returning subject, text and optional HTML.
    * `:deliver` — a function of arity two calling the application's mailer.
    * `:context` — passed unchanged to the content function; defaults to `%{}`.

  Disabled delivery returns `{:ok, :disabled}` without invoking either callback. Successful
  delivery returns `{:ok, receipt}`. Expected failures return `{:error, reason}` where reason
  is `:invalid_configuration`, `:invalid_recipient`, `:invalid_url`, `:transaction_in_progress`,
  `{:content, reason}` or `{:delivery, reason}`. A malformed callback result uses
  `:invalid_result` as its stage's reason. Callback exceptions propagate as programming errors.

  Subject and text must be non-empty strings; HTML is optional. Recipients use the practical
  syntax of `Ithibati.Schema.Identifier.email_format/0`. URLs must be absolute HTTP(S) URLs
  without user information. Content functions must escape dynamic values when rendering HTML.

  Delivery does not prove receipt or validate the invitation's state. Expiry and single-use
  acceptance remain enforced by `Ithibati.Identity.Invitations`. No token is stored or logged.
  A delivery error leaves the existing invitation intact. Retry with the same URL while the
  caller still holds it; after losing it, issue a replacement through the existing schema flow.
  A transport failure can be ambiguous, so retrying may deliver a duplicate email.
  """
  def deliver(recipient, url, opts \\ configured()) do
    case Keyword.get(opts, :enabled, false) do
      false -> {:ok, :disabled}
      true -> send_link(recipient, url, opts)
      _other -> {:error, :invalid_configuration}
    end
  end

  defp configured, do: Application.get_env(:ithibati, :invitation_mail, [])

  defp send_link(recipient, url, opts) do
    with :ok <- callbacks(opts),
         :ok <- recipient(recipient),
         :ok <- url(url),
         :ok <- outside_transaction(),
         {:ok, content} <- render(opts[:content], url, Keyword.get(opts, :context, %{})) do
      deliver_content(opts[:deliver], recipient, content)
    end
  end

  defp callbacks(opts) do
    if is_function(opts[:content], 2) and is_function(opts[:deliver], 2),
      do: :ok,
      else: {:error, :invalid_configuration}
  end

  defp recipient(value) when is_binary(value) do
    if Regex.match?(Identifier.email_format(), value),
      do: :ok,
      else: {:error, :invalid_recipient}
  end

  defp recipient(_value), do: {:error, :invalid_recipient}

  defp url(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _other ->
        {:error, :invalid_url}
    end
  end

  defp url(_value), do: {:error, :invalid_url}

  defp outside_transaction do
    if Config.repo().in_transaction?(), do: {:error, :transaction_in_progress}, else: :ok
  end

  defp render(callback, url, context) do
    case callback.(url, context) do
      {:ok, %{subject: subject, text: text} = content}
      when is_binary(subject) and subject != "" and is_binary(text) and text != "" ->
        validate_content(content)

      {:error, reason} ->
        {:error, {:content, reason}}

      _other ->
        {:error, {:content, :invalid_result}}
    end
  end

  defp validate_content(content) do
    if String.contains?(content.subject, ["\r", "\n"]) or
         not is_binary(Map.get(content, :html, "")),
       do: {:error, {:content, :invalid_result}},
       else: {:ok, Map.take(content, [:subject, :text, :html])}
  end

  defp deliver_content(callback, recipient, content) do
    case callback.(recipient, content) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, reason} -> {:error, {:delivery, reason}}
      _other -> {:error, {:delivery, :invalid_result}}
    end
  end
end
