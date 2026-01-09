defmodule LidlChef.RerankerQuickBenchTest do
  use ExUnit.Case, async: false

  alias LidlChef.Reranker
  require Logger

  @moduletag timeout: :infinity

  describe "Quick Reranker Benchmark" do
    test "compare sequential vs parallel with 10 chunks" do
      question = "recetas con pollo y arroz"
      chunks = create_mock_chunks(10)

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("QUICK BENCHMARK - 10 chunks")
      IO.puts(String.duplicate("=", 80))

      # Sequential (concurrency=1)
      {seq_time_us, {:ok, seq_results}} =
        :timer.tc(fn ->
          Reranker.rerank(question, chunks, concurrency: 1, threshold: 0)
        end)

      seq_time_ms = div(seq_time_us, 1000)
      IO.puts("Sequential (c=1):  #{seq_time_ms}ms → #{length(seq_results)} results")

      # Parallel (concurrency=5)
      {par5_time_us, {:ok, par5_results}} =
        :timer.tc(fn ->
          Reranker.rerank(question, chunks, concurrency: 5, threshold: 0)
        end)

      par5_time_ms = div(par5_time_us, 1000)
      IO.puts("Parallel (c=5):    #{par5_time_ms}ms → #{length(par5_results)} results")

      # Parallel (concurrency=10)
      {par10_time_us, {:ok, par10_results}} =
        :timer.tc(fn ->
          Reranker.rerank(question, chunks, concurrency: 10, threshold: 0)
        end)

      par10_time_ms = div(par10_time_us, 1000)
      IO.puts("Parallel (c=10):   #{par10_time_ms}ms → #{length(par10_results)} results")

      IO.puts("\n📊 Analysis:")

      if par10_time_ms < seq_time_ms do
        speedup = Float.round(seq_time_ms / par10_time_ms, 2)
        IO.puts("✅ Parallel is faster! Speedup: #{speedup}x")
      else
        IO.puts("⚠️  No speedup detected - LLM server may be processing requests sequentially")
        IO.puts("   This is expected if the server has limited concurrent request handling")
      end

      IO.puts(String.duplicate("=", 80) <> "\n")

      # Verify all approaches return results (should be 10 results with threshold 0)
      assert length(seq_results) == 10, "Sequential should return 10 results"
      assert length(par5_results) == 10, "Parallel (5) should return 10 results"
      assert length(par10_results) == 10, "Parallel (10) should return 10 results"
    end

    test "test with different chunk sizes" do
      question = "recetas rápidas y fáciles"

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("SCALING TEST")
      IO.puts(String.duplicate("=", 80))

      for chunk_count <- [5, 10, 20] do
        chunks = create_mock_chunks(chunk_count)

        {time_us, {:ok, results}} =
          :timer.tc(fn ->
            Reranker.rerank(question, chunks, concurrency: 5, threshold: 0)
          end)

        time_ms = div(time_us, 1000)
        per_chunk = Float.round(time_ms / chunk_count, 1)

        IO.puts(
          "#{String.pad_leading(to_string(chunk_count), 2)} chunks: #{String.pad_leading(to_string(time_ms), 6)}ms (#{per_chunk}ms/chunk) → #{length(results)} results"
        )
      end

      IO.puts(String.duplicate("=", 80) <> "\n")
    end
  end

  # Helper to create mock chunks for testing
  defp create_mock_chunks(count) do
    recipes = [
      {"Arroz con Pollo", "arroz, pollo, cebolla, pimiento, tomate, ajo"},
      {"Paella Valenciana", "arroz, pollo, conejo, judías verdes, garrofón"},
      {"Risotto de Champiñones", "arroz arborio, champiñones, cebolla, vino blanco, parmesano"},
      {"Pollo al Curry", "pollo, curry, leche de coco, cebolla, arroz, jengibre"},
      {"Ensalada de Pollo", "pollo, lechuga, tomate, maíz, aguacate, limón"},
      {"Sopa de Pollo", "pollo, zanahoria, apio, fideos, cebolla, perejil"},
      {"Tacos de Pollo", "pollo, tortillas, lechuga, tomate, queso, salsa"},
      {"Lasaña de Pollo", "pollo, pasta lasaña, bechamel, queso, tomate"},
      {"Pollo Teriyaki", "pollo, salsa teriyaki, arroz, sésamo, cebolleta"},
      {"Croquetas de Pollo", "pollo, leche, harina, pan rallado, huevo"}
    ]

    1..count
    |> Enum.map(fn i ->
      {name, ingredients} = Enum.at(recipes, rem(i, length(recipes)))

      %{
        text: """
        Recipe: #{name}
        Ingredients: #{ingredients}
        Preparation time: #{30 + rem(i * 7, 60)} minutes
        Servings: #{2 + rem(i, 4)}
        Difficulty: #{Enum.at(["Easy", "Medium", "Hard"], rem(i, 3))}
        Description: A delicious #{String.downcase(name)} recipe perfect for any occasion.
        This dish combines traditional flavors with modern cooking techniques.
        """,
        document_id: "recipe_#{i}",
        chunk_id: "chunk_#{i}",
        score: 0.75 + rem(i, 25) / 100.0
      }
    end)
  end
end
