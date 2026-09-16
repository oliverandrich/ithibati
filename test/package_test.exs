defmodule Ithibati.PackageTest do
  use ExUnit.Case, async: true

  # Hex replaces its default file list with `package(files:)` rather than extending it, so a
  # directory added to the repository does not reach the published package until somebody also
  # names it in mix.exs. Nothing local fails when they forget: every test reads the working tree,
  # where the file is present. The first consumer finds out instead.
  @shippable ~w(lib priv src docs)

  # Files rather than directories, and named one by one: a directory is shippable because of what it
  # is, a loose file because of what it does. `package.json` is what makes `import … from "ithibati"`
  # resolve; that it *does* resolve is proven against a real bundler in
  # `examples/open_registration/test/ithibati_open/bundling_test.exs`, and this is the half that
  # makes sure it reaches the consumer at all.
  @shippable_files ~w(package.json)

  test "every shippable directory that exists is in the package file list" do
    files = Mix.Project.config()[:package][:files]

    for dir <- @shippable, File.dir?(dir) do
      assert dir in files,
             "#{dir}/ exists but is missing from package(files:) in mix.exs — it would be absent " <>
               "from the published package"
    end
  end

  test "every shippable loose file that exists is in the package file list" do
    files = Mix.Project.config()[:package][:files]

    for file <- @shippable_files, File.regular?(file) do
      assert file in files,
             "#{file} exists but is missing from package(files:) in mix.exs — it would be absent " <>
               "from the published package"
    end
  end

  # The two had drifted, and nothing said so: hex.pm was still advertising revocable tokens after
  # the library had stopped issuing any. The README's opening paragraph is the description, so a
  # rewrite of one has to reach the other.
  test "the package description is the paragraph the README opens with" do
    # The *first* paragraph that is prose, found by position rather than by its opening words. A
    # search for the words would be a third copy of the text these two are being held to, and it
    # would stay green for a README whose opening paragraph had moved to the bottom.
    opening =
      "README.md"
      |> File.read!()
      |> String.split(~r/\n\s*\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.find(&(not String.starts_with?(&1, ["#", "![", "[", ">"])))

    refute is_nil(opening), "README.md has no prose paragraph for the description to match"

    assert normalise(opening) == normalise(Mix.Project.config()[:description])
  end

  # The card the documentation site hands a scraper. Both halves are things mix.exs *states* and
  # the file *is*, which is the shape that drifts: a replaced logo, or a description that grows a
  # quotation mark and silently truncates the attribute it sits in.
  describe "the social card" do
    # The signature and the IHDR marker are asserted rather than skipped over. Without them the
    # pattern matches any file of twenty-four bytes or more, so a JPEG saved under a `.png` name
    # — which is exactly the "somebody replaced the logo" case — would read two arbitrary words
    # as the dimensions and fail with a bare number mismatch.
    test "claims the dimensions the image actually has" do
      <<"\x89PNG\r\n\x1a\n", _length::32, "IHDR", width::32, height::32, _::binary>> =
        File.read!("assets/logo.png")

      card = Ithibati.MixProject.social_card(:html)

      assert card =~ ~s(<meta property="og:image:width" content="#{width}">)
      assert card =~ ~s(<meta property="og:image:height" content="#{height}">)
    end

    # `assets:` in `docs/0` is what puts the file where the URL says it is. Change that map and
    # the card 404s on every page while every other assertion here stays green.
    test "points at the path the build actually writes the image to" do
      [{_source, target}] = Map.to_list(Mix.Project.config()[:docs][:assets])

      assert Ithibati.MixProject.social_card(:html) =~ ~s(/#{target}/logo.png")
    end

    test "escapes the description rather than demanding it stay free of markup" do
      assert Ithibati.MixProject.escape(~s(a & b < c > d "e")) ==
               "a &amp; b &lt; c &gt; d &quot;e&quot;"

      assert Ithibati.MixProject.social_card(:html) =~
               ~s(<meta property="og:description" content="#{Mix.Project.config()[:description]}">)
    end

    # The one decision the comment in mix.exs argues at length: with no `og:title`, a scraper
    # falls back to the per-page `<title>`, so a link to one guide does not present itself as a
    # link to the whole site.
    test "sets no og:title, so the page keeps its own" do
      refute Ithibati.MixProject.social_card(:html) =~ "og:title"
    end

    test "is empty for any format that has no head to put it in" do
      assert Ithibati.MixProject.social_card(:epub) == ""
      assert Ithibati.MixProject.social_card(:markdown) == ""
    end
  end

  # ExDoc writes the documentation root from a redirect template that takes no head hook, so the
  # card is patched in afterwards. That patch is a string replacement, and a string replacement
  # that stops matching answers the string it was given.
  describe "the patch onto ExDoc's redirect page" do
    test "puts the card in front of the closing head tag" do
      patched = Ithibati.MixProject.with_card("<html><head><title>x</title></head></html>")

      assert patched =~ ~r|<meta property="og:image".*</head>|s
      assert patched =~ "<title>x</title>"
    end

    test "leaves a page that already carries one alone" do
      once = Ithibati.MixProject.with_card("<html><head></head></html>")

      assert Ithibati.MixProject.with_card(once) == once
    end

    test "refuses a page it cannot patch rather than answering it unchanged" do
      assert_raise Mix.Error, ~r|no </head>|, fn ->
        Ithibati.MixProject.with_card("<html><body>nothing to patch</body></html>")
      end
    end
  end

  # Line breaks are the author's business, and a hard break at the end of a line is invisible.
  defp normalise(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
