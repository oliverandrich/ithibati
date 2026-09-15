defmodule Ithibati.DocumentationPointersTest do
  @moduledoc """
  Every reference to a documentation page reaches a page, and a heading in it.

  There are three ways to write one and three places to write it from, and each combination rots
  on its own. `mix docs --warnings-as-errors` reads the markdown links inside the published
  documentation and stops at the filename — what follows `#` is re-appended verbatim, never
  resolved — and it never reads the README at all, because the README is not one of the extras.
  So a renamed heading, a moved page named in a comment, and the README's absolute `hexdocs.pm`
  links were each invisible in a different way. Splitting the README into a site produced all
  three at once.

  Which renderer resolves a link depends on where it is written, because the two slug a heading
  differently: a full stop or an apostrophe inside a word becomes a hyphen under ExDoc and
  vanishes under GitHub. Pages under `docs/` and doc comments under `lib/` are read on the
  documentation site; the README and `AGENTS.md` are read on GitHub. An absolute `hexdocs.pm` link
  is the site's wherever it was written.
  """
  use ExUnit.Case, async: true

  @prose Ithibati.Prose.pages()
  @commented Path.wildcard("{lib,test,priv}/**/*.{ex,exs,js}")

  # The pages the site publishes, by the name their URL carries. Taken from `docs(:extras)` rather
  # than from the filesystem: a page that exists and is not an extra has no URL, and an absolute
  # link to it would 404.
  @site Mix.Project.config()[:docs][:extras]
        |> Enum.map(fn
          {page, _opts} -> to_string(page)
          page -> to_string(page)
        end)
        |> Map.new(&{&1 |> Path.basename() |> Path.rootname() |> String.downcase(), &1})

  @markdown_link ~r/\]\(([\w.\/-]+\.md)(#[\w-]+)?\)/
  @hexdocs_link ~r/https:\/\/hexdocs\.pm\/ithibati\/([\w-]+)\.html(#[\w-]+)?/
  @named_page ~r/(docs\/[\w-]+\.md)/

  describe "a page named in prose" do
    test "exists" do
      named =
        for file <- @commented,
            [_, page] <- Regex.scan(@named_page, File.read!(file)),
            do: {file, page}

      refute named == [], "no pages named at all — this test would pass vacuously"

      for {file, page} <- named do
        assert File.exists?(page), "#{file} names #{page}, which does not exist"
      end
    end
  end

  describe "a markdown link" do
    test "reaches a page" do
      links = markdown_links()

      refute links == [], "no markdown links found at all — this test would pass vacuously"

      for {file, link, _anchor} <- links, do: assert_resolves(file, link)
    end

    test "and a heading in it, under the renderer that will resolve it" do
      links =
        for {file, link, anchor} <- markdown_links(), anchor != nil, do: {file, link, anchor}

      refute links == [], "no anchored links found at all — this test would pass vacuously"

      for {file, link, anchor} <- links do
        page = resolve(file, link)

        assert anchor in anchors(page, renderer(file)),
               "#{file} links to #{link}##{anchor}, which no heading in #{page} makes under " <>
                 "#{renderer(file)}"
      end
    end
  end

  describe "an absolute link to the site" do
    test "names a page the site publishes, and a heading in it" do
      links =
        for file <- @prose ++ @commented,
            [_, name | rest] <- Regex.scan(@hexdocs_link, File.read!(file)),
            do: {file, name, rest |> List.first() |> anchor_of()}

      refute links == [], "no hexdocs links found at all — this test would pass vacuously"

      for {file, name, anchor} <- links do
        assert page = Map.get(@site, name),
               "#{file} links to #{name}.html, which this project does not publish"

        if anchor do
          assert anchor in anchors(page, :exdoc),
                 "#{file} links to #{name}.html##{anchor}, which no heading in #{page} makes"
        end
      end
    end
  end

  # A link in a prose file is a path, the way GitHub reads it. A link in a doc comment is a page
  # name, the way ExDoc resolves an extra — there is no such file beside the module.
  defp markdown_links do
    for file <- @prose ++ Path.wildcard("lib/**/*.ex"),
        [_, link | rest] <- Regex.scan(@markdown_link, File.read!(file)),
        do: {file, link, rest |> List.first() |> anchor_of()}
  end

  defp anchor_of(nil), do: nil
  defp anchor_of(""), do: nil
  defp anchor_of("#" <> anchor), do: anchor

  defp assert_resolves(file, link) do
    assert resolve(file, link), "#{file} links to #{link}, which is not a page"
  end

  defp resolve(file, link) do
    if file in @prose do
      path = file |> Path.dirname() |> Path.join(link) |> Path.expand() |> Path.relative_to_cwd()
      if File.exists?(path), do: path
    else
      Map.get(@site, link |> Path.basename() |> Path.rootname() |> String.downcase())
    end
  end

  defp renderer("docs/" <> _rest), do: :exdoc
  defp renderer("lib/" <> _rest), do: :exdoc
  defp renderer(_read_on_github), do: :github

  defp anchors(page, renderer) do
    ~r/^#+ (.+)$/m
    |> Regex.scan(File.read!(page))
    |> MapSet.new(fn [_, heading] -> anchor(heading, renderer) end)
  end

  # Lower case, punctuation dropped, spaces to hyphens.
  defp anchor(heading, :github) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end

  # `ExDoc.Utils.text_to_id/1`: every run of anything that is not a word character becomes one
  # hyphen. Written out rather than called, because that module is `@moduledoc false` and ex_doc
  # is a `dev` dependency this suite does not have.
  defp anchor(heading, :exdoc) do
    heading
    |> String.replace(~r/\W+/u, "-")
    |> String.trim("-")
    |> String.downcase()
  end
end
