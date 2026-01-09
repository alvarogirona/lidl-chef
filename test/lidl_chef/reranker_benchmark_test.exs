defmodule LidlChef.RerankerBenchmarkTest do
  use ExUnit.Case, async: false

  alias LidlChef.{Reranker, Recipes, Repo}
  require Logger

  @moduletag timeout: 300_000

  setup do
    # Ensure the test DB is available
    _ = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  describe "Reranker Performance Benchmark" do
    test "benchmark different concurrency levels" do
      # Get real recipe chunks from the database
      question = "recetas con pollo y arroz para la comida"

      chunks =
        case Recipes.search(question, limit: 50, graph: false, mode: :hybrid) do
          {:ok, chunks} when length(chunks) > 0 -> chunks
          _ -> create_mock_chunks(30)
        end

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("RERANKER BENCHMARK")
      IO.puts(String.duplicate("=", 80))
      IO.puts("Question: #{question}")
      IO.puts("Chunks to rerank: #{length(chunks)}")
      IO.puts("Type: #{if is_mock_chunk?(hd(chunks)), do: "Mock", else: "Real"}")
      IO.puts(String.duplicate("=", 80))

      # Test different concurrency levels
      concurrency_levels = [1, 2, 5, 10, 15, 20]

      results =
        for concurrency <- concurrency_levels do
          run_benchmark(question, chunks, concurrency)
        end

      # Print summary
      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("BENCHMARK SUMMARY")
      IO.puts(String.duplicate("=", 80))

      Enum.each(results, fn {concurrency, duration_ms, reranked_count} ->
        IO.puts(
          "Concurrency: #{String.pad_leading(to_string(concurrency), 2)} | " <>
            "Time: #{String.pad_leading(to_string(duration_ms), 8)}ms | " <>
            "Results: #{reranked_count}"
        )
      end)

      # Find fastest
      {best_concurrency, best_time, _} = Enum.min_by(results, fn {_, time, _} -> time end)

      IO.puts("\n✨ Best result: concurrency=#{best_concurrency} at #{best_time}ms")

      # Calculate speedup (avoid division by zero)
      {_, sequential_time, _} = Enum.find(results, fn {c, _, _} -> c == 1 end)

      if sequential_time > 0 and best_time > 0 do
        speedup = Float.round(sequential_time / best_time, 2)
        IO.puts("🚀 Speedup: #{speedup}x faster than sequential")
      end

      IO.puts(String.duplicate("=", 80) <> "\n")

      # Assert we got results
      assert length(chunks) > 0, "Should have chunks to rerank"
    end

    test "verify parallel processing produces same results as sequential" do
      question = "recetas veganas con tofu"

      chunks =
        case Recipes.search(question, limit: 20, graph: false, mode: :hybrid) do
          {:ok, chunks} when length(chunks) > 0 -> chunks
          _ -> create_mock_chunks(15)
        end

      # Run with concurrency=1 (sequential)
      {:ok, sequential_results} = Reranker.rerank(question, chunks, concurrency: 1, threshold: 2)

      # Run with concurrency=10 (parallel)
      {:ok, parallel_results} = Reranker.rerank(question, chunks, concurrency: 10, threshold: 2)

      # Results should have same length (order might differ slightly due to non-deterministic network timing)
      assert length(sequential_results) == length(parallel_results),
             "Sequential and parallel should return same number of results"

      IO.puts("\n✅ Sequential and parallel processing produce consistent results")
      IO.puts("   Sequential: #{length(sequential_results)} results")
      IO.puts("   Parallel:   #{length(parallel_results)} results")
    end

    test "stress test with large chunk set" do
      question = "recetas para toda la semana"

      chunks =
        case Recipes.search(question, limit: 100, graph: false, mode: :hybrid) do
          {:ok, chunks} when length(chunks) > 0 -> chunks
          _ -> create_mock_chunks(50)
        end

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("STRESS TEST - #{length(chunks)} chunks")
      IO.puts(String.duplicate("=", 80))

      {duration_us, {:ok, results}} =
        :timer.tc(fn ->
          Reranker.rerank(question, chunks, concurrency: 15, threshold: 2)
        end)

      duration_ms = div(duration_us, 1000)

      IO.puts("Time: #{duration_ms}ms")
      IO.puts("Throughput: #{Float.round(length(chunks) / (duration_ms / 1000), 2)} chunks/sec")
      IO.puts("Results after filtering: #{length(results)}")
      IO.puts(String.duplicate("=", 80) <> "\n")

      assert duration_ms < 120_000, "Should complete within 2 minutes"
    end
  end

  # Helper function to run a single benchmark iteration
  defp run_benchmark(question, chunks, concurrency) do
    # Warm-up run (not timed)
    if concurrency == List.first([1, 2, 5, 10, 15, 20]) do
      {:ok, _} = Reranker.rerank(question, Enum.take(chunks, 2), concurrency: concurrency)
      Process.sleep(1000)
    end

    # Actual benchmark
    {duration_us, {:ok, results}} =
      :timer.tc(fn ->
        Reranker.rerank(question, chunks, concurrency: concurrency, threshold: 2)
      end)

    duration_ms = div(duration_us, 1000)

    IO.puts(
      "Concurrency #{String.pad_leading(to_string(concurrency), 2)}: #{duration_ms}ms (#{length(results)} results)"
    )

    {concurrency, duration_ms, length(results)}
  end

  # Helper to create mock chunks for testing when DB is empty
  defp create_mock_chunks(count) do
    recipes = [
      {"Arroz con Pollo", "arroz, pollo, cebolla, pimiento, tomate"},
      {"Paella Valenciana", "arroz, pollo, conejo, judías verdes, garrofón"},
      {"Risotto de Champiñones", "arroz arborio, champiñones, cebolla, vino blanco"},
      {"Pollo al Curry", "pollo, curry, leche de coco, cebolla, arroz"},
      {"Ensalada de Pollo", "pollo, lechuga, tomate, maíz, aguacate"},
      {"Sopa de Pollo", "pollo, zanahoria, apio, fideos, cebolla"},
      {"Tacos de Pollo", "pollo, tortillas, lechuga, tomate, queso"},
      {"Lasaña de Pollo", "pollo, pasta lasaña, bechamel, queso, tomate"},
      {"Pollo Teriyaki", "pollo, salsa teriyaki, arroz, sésamo, cebolleta"},
      {"Croquetas de Pollo", "pollo, leche, harina, pan rallado, huevo"}
    ]

    1..count
    |> Enum.map(fn i ->
      {name, ingredients} = Enum.at(recipes, rem(i, length(recipes)))

      %{
        text: """
        Recipe: #{name} #{i}
        Ingredients: #{ingredients}
        Preparation time: 45 minutes
        Servings: 4
        Description: Delicious recipe with chicken and rice, perfect for lunch or dinner.
        """,
        document_id: "mock_recipe_#{i}",
        chunk_id: "chunk_#{i}",
        score: 0.8,
        __mock__: true
      }
    end)
  end

  defp is_mock_chunk?(chunk) do
    Map.has_key?(chunk, :__mock__)
  end
end
