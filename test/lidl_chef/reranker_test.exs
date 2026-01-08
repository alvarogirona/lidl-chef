defmodule LidlChef.RerankerTest do
  use LidlChef.DataCase, async: false

  alias LidlChef.Reranker

  @moduletag :reranker

  describe "rerank/3" do
    test "returns empty list when no chunks provided" do
      assert {:ok, []} = Reranker.rerank("any question", [], [])
    end

    @tag :external
    test "reranks chunks for tofu recipe query" do
      # Create mock chunks that simulate recipe data from the database
      # These simulate Arcana chunk format with :text field
      chunks = [
        %{
          id: 1,
          text: """
          Nombre: Tofu al curry con arroz
          Ingredientes: tofu firme, leche de coco, curry, arroz basmati, cebolla, ajo, jengibre
          Descripción: Un delicioso plato asiático con tofu marinado en curry y servido sobre arroz basmati.
          URL: https://recetas.lidl.es/tofu-curry-arroz
          """
        },
        %{
          id: 2,
          text: """
          Nombre: Ensalada mediterránea con pollo
          Ingredientes: pollo, lechuga, tomate, pepino, aceitunas, queso feta, aceite de oliva
          Descripción: Ensalada fresca y nutritiva con pollo a la plancha y verduras frescas.
          URL: https://recetas.lidl.es/ensalada-mediterranea-pollo
          """
        },
        %{
          id: 3,
          text: """
          Nombre: Revuelto de tofu y verduras
          Ingredientes: tofu, calabacín, pimiento rojo, champiñones, salsa de soja, aceite de sésamo
          Descripción: Salteado rápido y saludable de tofu con verduras de temporada.
          URL: https://recetas.lidl.es/revuelto-tofu-verduras
          """
        }
      ]

      question = "Que puedo cocinar con tofu?"

      IO.puts("\n=== Starting Reranker Test ===")
      IO.puts("Question: #{question}")
      IO.puts("Chunks count: #{length(chunks)}")

      {:ok, reranked} = Reranker.rerank(question, chunks, threshold: 3)

      IO.puts("Reranked count: #{length(reranked)}")
      IO.puts("Reranked IDs: #{inspect(Enum.map(reranked, & &1.id))}")
      IO.puts("==============================\n")

      # Verify we got results
      assert length(reranked) > 0, "Should return at least one reranked chunk"

      # Verify tofu recipes are ranked higher
      reranked_ids = Enum.map(reranked, & &1.id)

      # Tofu recipes (ids 1, 3) should be in results
      tofu_recipe_ids = [1, 3]
      matched_tofu_ids = Enum.filter(reranked_ids, &(&1 in tofu_recipe_ids))

      assert length(matched_tofu_ids) > 0,
             "At least one tofu recipe should pass the threshold. Got: #{inspect(reranked_ids)}"
    end
  end
end
