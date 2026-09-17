defmodule Ithibati.Vocabulary do
  @moduledoc false
  # Reading a set of codes out of a file, for the guards that hold two files to the same list.
  # Three of them ask it now — the guide against the code, the JavaScript against the code, and
  # the walkthrough against the example — and a copy in each is three chances for one to drift
  # into a laxer assertion than its neighbours.

  @doc "Every code the pattern's first group captures, as atoms."
  def codes_in(source, pattern) do
    pattern
    |> Regex.scan(source)
    |> Enum.map(fn [_, code] -> String.to_atom(code) end)
    |> MapSet.new()
  end

  @doc """
  Asserts two sets are equal and says which side each difference is on.

  `left` and `right` name the places, so a failure reads as the question that was asked.
  """
  defmacro assert_same(found, expected, left, right) do
    quote bind_quoted: [found: found, expected: expected, left: left, right: right] do
      refute MapSet.size(found) == 0, "#{left} named nothing — this would pass vacuously"

      assert MapSet.equal?(found, expected), """
      #{left} and #{right} disagree.

      Only in #{left}:  #{inspect(Enum.sort(MapSet.difference(found, expected)))}
      Only in #{right}: #{inspect(Enum.sort(MapSet.difference(expected, found)))}
      """
    end
  end
end
