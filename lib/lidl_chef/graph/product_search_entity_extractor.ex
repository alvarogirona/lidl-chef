defmodule LidlChef.Graph.ProductSearchEntityExtractor do
  @behaviour Arcana.Graph.EntityExtractor

  def extract(text, opts \\ []) do
    extracted_entities = text
    |> String.split([",", " "])
    |> Enum.map(fn str -> %{name: str} end)
    {:ok, extracted_entities}
  end
end
