defmodule Ithibati.SurfaceProbe do
  @moduledoc """
  A surface that exists to be read.

  `Ithibati.Credo.NoInternalCalls` carries no list of what is internal — it asks each module. That
  claim is only worth something if a function it has never heard of is treated correctly, which is
  what this module is: two functions, one documented and one not, neither named anywhere in the
  check.
  """

  @doc "Documented, and so not the check's business."
  def open, do: :ok

  @doc false
  def closed, do: :ok
end
