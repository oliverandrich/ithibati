defmodule Ithibati.InvitationMailTest do
  use Ithibati.DataCase, async: true

  alias Ithibati.InvitationMail

  @url "https://example.test/invite/secret"
  @recipient "ada@example.test"

  defp options do
    caller = self()

    [
      enabled: true,
      context: %{locale: "de"},
      content: fn url, context ->
        send(caller, {:rendered, url, context})
        {:ok, %{subject: "Welcome", text: "Open #{url}"}}
      end,
      deliver: fn recipient, content ->
        send(caller, {:delivered, recipient, content})
        {:ok, :receipt}
      end
    ]
  end

  test "renders and delivers an existing link to an explicit recipient" do
    assert {:ok, :receipt} = InvitationMail.deliver(@recipient, @url, options())
    assert_received {:rendered, @url, %{locale: "de"}}
    assert_received {:delivered, @recipient, %{subject: "Welcome", text: "Open " <> @url}}
  end

  test "passes both text and HTML to the application's mailer callback" do
    content = %{subject: "Welcome", text: @url, html: "<p>#{@url}</p>"}
    opts = Keyword.put(options(), :content, fn _, _ -> {:ok, content} end)

    assert {:ok, :receipt} = InvitationMail.deliver(@recipient, @url, opts)
    assert_received {:delivered, @recipient, ^content}
  end

  test "delivery is opt-in and disabling it invokes neither callback" do
    refute InvitationMail.enabled?([])
    assert InvitationMail.enabled?(options())

    for opts <- [[], Keyword.put(options(), :enabled, false)] do
      assert {:ok, :disabled} = InvitationMail.deliver(nil, nil, opts)
      refute_received {:rendered, _, _}
      refute_received {:delivered, _, _}
    end
  end

  test "rejects invalid configuration before rendering" do
    for opts <- [[enabled: true], Keyword.put(options(), :deliver, nil)] do
      assert {:error, :invalid_configuration} = InvitationMail.deliver(@recipient, @url, opts)
      refute_received {:rendered, _, _}
    end
  end

  test "refuses malformed recipients and links before callbacks" do
    for recipient <- [nil, "ada", "ada@example.test\r\nBcc: other@example.test"] do
      assert {:error, :invalid_recipient} = InvitationMail.deliver(recipient, @url, options())
    end

    for url <- [
          nil,
          "/invite/token",
          "javascript:alert(1)",
          "https://user:pass@example.test/invite"
        ] do
      assert {:error, :invalid_url} = InvitationMail.deliver(@recipient, url, options())
    end

    refute_received {:rendered, _, _}
    refute_received {:delivered, _, _}
  end

  test "reports content failures without calling delivery" do
    opts = Keyword.put(options(), :content, fn _, _ -> {:error, :template_missing} end)

    assert {:error, {:content, :template_missing}} =
             InvitationMail.deliver(@recipient, @url, opts)

    refute_received {:delivered, _, _}
  end

  test "refuses incomplete or malformed content" do
    for content <- [
          nil,
          "text",
          %{subject: "Welcome"},
          %{subject: "", text: "body"},
          %{subject: "Welcome\nBcc: other", text: "body"},
          %{subject: "Welcome", text: "body", html: 42}
        ] do
      opts = Keyword.put(options(), :content, fn _, _ -> {:ok, content} end)

      assert {:error, {:content, :invalid_result}} =
               InvitationMail.deliver(@recipient, @url, opts)

      refute_received {:delivered, _, _}
    end
  end

  test "distinguishes delivery failures and invalid callback results" do
    opts = Keyword.put(options(), :deliver, fn _, _ -> {:error, :unavailable} end)
    assert {:error, {:delivery, :unavailable}} = InvitationMail.deliver(@recipient, @url, opts)

    opts = Keyword.put(options(), :deliver, fn _, _ -> :ok end)
    assert {:error, {:delivery, :invalid_result}} = InvitationMail.deliver(@recipient, @url, opts)

    opts = Keyword.put(options(), :content, fn _, _ -> :ok end)
    assert {:error, {:content, :invalid_result}} = InvitationMail.deliver(@recipient, @url, opts)
  end

  test "refuses side effects in a transaction even when it later rolls back" do
    assert {:error, :cancelled} =
             TestRepo.transaction(fn ->
               assert {:error, :transaction_in_progress} =
                        InvitationMail.deliver(@recipient, @url, options())

               TestRepo.rollback(:cancelled)
             end)

    refute_received {:rendered, _, _}
    refute_received {:delivered, _, _}
    assert {:ok, :receipt} = InvitationMail.deliver(@recipient, @url, options())
  end
end
