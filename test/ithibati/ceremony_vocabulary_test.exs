defmodule Ithibati.CeremonyVocabularyTest do
  @moduledoc """
  The three places that name this library's failure codes say the same thing.

  `Ithibati.Ceremony` is the list, `docs/ceremonies.md` is where a consumer reads it, and
  `priv/static/ithibati.js` is where half of it is sent from. Adding a word used to take four hand
  edits, which is how `recovery_failed` came to be sendable since the first release and documented
  nowhere.

  The JavaScript is read rather than executed, so it declares its codes in one object this can
  find. A literal written anywhere else in that file is invisible here.
  """
  use ExUnit.Case, async: true

  import Ithibati.Vocabulary

  alias Ithibati.Ceremony
  alias Ithibati.Vocabulary

  @guide File.read!("docs/ceremonies.md")
  @javascript File.read!("priv/static/ithibati.js")

  test "the guide's table is the list, exactly" do
    documented = Vocabulary.codes_in(@guide, ~r/^\| `([a-z_]+)` \|/m)

    assert_same(
      documented,
      MapSet.new(Ceremony.codes()),
      "the guide's table",
      "Ithibati.Ceremony"
    )
  end

  test "the browser half sends exactly the words the library says it does" do
    [[_, block]] = Regex.scan(~r/const CODES = \{(.*?)\n\}/s, @javascript)
    sent = Vocabulary.codes_in(block, ~r/"([a-z_]+)"/)

    assert_same(sent, MapSet.new(Ceremony.browser_codes()), "the JavaScript", "Ithibati.Ceremony")
  end

  # A family cannot be a table row, so it must not be in the list either: a consumer matching on
  # `codes/0` would never match `http_404`.
  test "the families are named apart, and are not in the list" do
    for family <- Ceremony.families() do
      refute family in Ceremony.codes()
      assert @guide =~ "`#{family}_<"
    end
  end
end
