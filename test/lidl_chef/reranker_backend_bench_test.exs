defmodule LidlChef.RerankerBackendBenchTest do
  use ExUnit.Case, async: false

  alias LidlChef.Reranker
  alias Arcana.Chunk
  require Logger

  @moduletag timeout: :infinity

  describe "Backend Comparison Benchmark" do
    test "compare CPU vs Vulkan backend performance" do
      question = "recetas con pollo y arroz"
      chunks = create_mock_chunks(20)

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("BACKEND COMPARISON BENCHMARK - 20 chunks")
      IO.puts(String.duplicate("=", 80))
      IO.puts("")

      # CPU Backend (port 8080)
      IO.puts("🖥️  Testing CPU Backend (port 8080)...")
      cpu_results = run_backend_test(8080, chunks, question, "CPU")

      # Vulkan Backend (port 8081)
      IO.puts("\n🎮 Testing Vulkan Backend (port 8081)...")
      vulkan_results = run_backend_test(8081, chunks, question, "Vulkan")

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("📊 PERFORMANCE COMPARISON")
      IO.puts(String.duplicate("=", 80))
      IO.puts("")

      print_comparison_table(cpu_results, vulkan_results)

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("")

      # Assertions
      assert cpu_results.seq_count == 20, "CPU sequential should return 20 results"
      assert cpu_results.par_count == 20, "CPU parallel should return 20 results"
      assert vulkan_results.seq_count == 20, "Vulkan sequential should return 20 results"
      assert vulkan_results.par_count == 20, "Vulkan parallel should return 20 results"
    end
  end

  defp run_backend_test(port, chunks, question, backend_name) do
    base_url = "http://127.0.0.1:#{port}"

    # Sequential (c=1)
    {seq_time_us, {:ok, seq_results}} =
      :timer.tc(fn ->
        Reranker.rerank(question, chunks, concurrency: 1, threshold: 0, base_url: base_url)
      end)

    seq_time_ms = div(seq_time_us, 1000)
    IO.puts("  Sequential (c=1):  #{seq_time_ms}ms → #{length(seq_results)} results")

    # Parallel (c=10)
    {par_time_us, {:ok, par_results}} =
      :timer.tc(fn ->
        Reranker.rerank(question, chunks, concurrency: 10, threshold: 0, base_url: base_url)
      end)

    par_time_ms = div(par_time_us, 1000)
    IO.puts("  Parallel (c=10):   #{par_time_ms}ms → #{length(par_results)} results")

    speedup = if par_time_ms > 0, do: Float.round(seq_time_ms / par_time_ms, 2), else: 0.0
    IO.puts("  Speedup: #{speedup}x")

    %{
      backend: backend_name,
      seq_time: seq_time_ms,
      par_time: par_time_ms,
      speedup: speedup,
      seq_count: length(seq_results),
      par_count: length(par_results)
    }
  end

  defp print_comparison_table(cpu, vulkan) do
    IO.puts("Backend         | Sequential | Parallel  | Speedup | vs CPU Par")
    IO.puts("----------------|------------|-----------|---------|------------")

    cpu_par_baseline = cpu.par_time

    IO.puts(
      "#{String.pad_trailing(cpu.backend, 15)} | " <>
        "#{String.pad_leading("#{cpu.seq_time}ms", 10)} | " <>
        "#{String.pad_leading("#{cpu.par_time}ms", 9)} | " <>
        "#{String.pad_leading("#{cpu.speedup}x", 7)} | " <>
        "1.00x (baseline)"
    )

    vulkan_vs_cpu = Float.round(cpu_par_baseline / vulkan.par_time, 2)

    IO.puts(
      "#{String.pad_trailing(vulkan.backend, 15)} | " <>
        "#{String.pad_leading("#{vulkan.seq_time}ms", 10)} | " <>
        "#{String.pad_leading("#{vulkan.par_time}ms", 9)} | " <>
        "#{String.pad_leading("#{vulkan.speedup}x", 7)} | " <>
        "#{vulkan_vs_cpu}x"
    )

    IO.puts("")

    cond do
      vulkan_vs_cpu > 1.5 ->
        IO.puts("✅ Vulkan is significantly faster than CPU (#{vulkan_vs_cpu}x speedup)!")

      vulkan_vs_cpu > 1.1 ->
        IO.puts("✅ Vulkan is moderately faster than CPU (#{vulkan_vs_cpu}x speedup)")

      vulkan_vs_cpu > 0.9 ->
        IO.puts("⚖️  Vulkan and CPU have similar performance")

      true ->
        IO.puts("⚠️  CPU is faster than Vulkan (unexpected)")
    end
  end

  defp create_mock_chunks(count) do
    recipes = [
      {"Arroz con Pollo", "arroz, pollo, cebolla, pimiento, tomate"},
      {"Pollo al Horno", "pollo, patatas, romero, ajo, aceite de oliva"},
      {"Paella Valenciana", "arroz, pollo, conejo, judías verdes, garrofón"},
      {"Sopa de Pollo", "pollo, fideos, zanahoria, apio, cebolla"},
      {"Ensalada César", "lechuga, pollo, parmesano, pan tostado, salsa césar"},
      {"Lasaña de Pollo", "pollo, pasta lasaña, bechamel, queso, tomate"},
      {"Pollo Teriyaki", "pollo, salsa teriyaki, arroz, sésamo, cebolleta"},
      {"Croquetas de Pollo", "pollo, leche, harina, pan rallado, huevo"}
    ]

    1..count
    |> Enum.map(fn i ->
      {name, ingredients} = Enum.at(recipes, rem(i, length(recipes)))

      %Chunk{
        text: """
        Recipe: #{name}
        Ingredients: #{ingredients}
        Preparation time: #{30 + rem(i * 7, 60)} minutes
        Servings: #{2 + rem(i, 4)}
        Difficulty: #{Enum.at(["Easy", "Medium", "Hard"], rem(i, 3))}
        Description: A delicious #{String.downcase(name)} recipe perfect for any occasion.
        This dish combines traditional flavors with modern cooking techniques.
        """,
        metadata: %{}
      }
    end)
  end
end
