defmodule LidlChef.RerankerScalingBenchTest do
  use ExUnit.Case, async: false

  alias LidlChef.Reranker
  alias Arcana.Chunk
  require Logger

  @moduletag timeout: :infinity

  describe "Scaling Benchmark: CPU vs Vulkan" do
    test "compare backends across different chunk sizes" do
      question = "recetas con pollo y arroz"
      chunk_sizes = [5, 10, 20, 40]

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("SCALING BENCHMARK: CPU vs VULKAN")
      IO.puts(String.duplicate("=", 80))
      IO.puts("")

      results =
        Enum.map(chunk_sizes, fn size ->
          IO.puts("📊 Testing with #{size} chunks...")
          chunks = create_mock_chunks(size)

          cpu_time = benchmark_backend(8080, chunks, question, "CPU")
          vulkan_time = benchmark_backend(8081, chunks, question, "Vulkan")

          speedup = Float.round(cpu_time / vulkan_time, 2)

          IO.puts("  CPU: #{cpu_time}ms | Vulkan: #{vulkan_time}ms | Speedup: #{speedup}x")
          IO.puts("")

          %{size: size, cpu: cpu_time, vulkan: vulkan_time, speedup: speedup}
        end)

      IO.puts(String.duplicate("=", 80))
      IO.puts("📊 SCALING ANALYSIS")
      IO.puts(String.duplicate("=", 80))
      IO.puts("")

      print_scaling_table(results)

      IO.puts("\n" <> String.duplicate("=", 80))
      IO.puts("")

      # All tests should complete
      assert length(results) == length(chunk_sizes)
    end
  end

  defp benchmark_backend(port, chunks, question, _backend_name) do
    base_url = "http://127.0.0.1:#{port}"

    {time_us, {:ok, _results}} =
      :timer.tc(fn ->
        Reranker.rerank(question, chunks, concurrency: 10, threshold: 0, base_url: base_url)
      end)

    div(time_us, 1000)
  end

  defp print_scaling_table(results) do
    IO.puts("Chunks | CPU Time | Vulkan Time | Speedup | CPU ms/chunk | Vulkan ms/chunk")
    IO.puts("-------|----------|-------------|---------|--------------|----------------")

    Enum.each(results, fn %{size: size, cpu: cpu, vulkan: vulkan, speedup: speedup} ->
      cpu_per_chunk = Float.round(cpu / size, 1)
      vulkan_per_chunk = Float.round(vulkan / size, 1)

      IO.puts(
        "#{String.pad_leading(to_string(size), 6)} | " <>
          "#{String.pad_leading("#{cpu}ms", 8)} | " <>
          "#{String.pad_leading("#{vulkan}ms", 11)} | " <>
          "#{String.pad_leading("#{speedup}x", 7)} | " <>
          "#{String.pad_leading("#{cpu_per_chunk}", 12)} | " <>
          "#{String.pad_leading("#{vulkan_per_chunk}", 15)}"
      )
    end)

    IO.puts("")
    IO.puts("📈 Analysis:")

    avg_speedup =
      results
      |> Enum.map(& &1.speedup)
      |> Enum.sum()
      |> Kernel./(length(results))
      |> Float.round(2)

    IO.puts("  Average Vulkan speedup: #{avg_speedup}x")

    # Check if speedup is consistent
    speedups = Enum.map(results, & &1.speedup)
    max_speedup = Enum.max(speedups)
    min_speedup = Enum.min(speedups)
    variance = max_speedup - min_speedup

    if variance < 0.3 do
      IO.puts("  ✅ Consistent performance across all chunk sizes")
    else
      IO.puts("  ⚠️  Performance varies with chunk size (#{min_speedup}x - #{max_speedup}x)")
    end

    # Check if scaling is linear
    first = List.first(results)
    last = List.last(results)

    cpu_scaling_factor = last.cpu / first.cpu / (last.size / first.size)
    vulkan_scaling_factor = last.vulkan / first.vulkan / (last.size / first.size)

    IO.puts("")
    IO.puts("📊 Scaling Efficiency (1.0 = perfect linear scaling):")
    IO.puts("  CPU:    #{Float.round(cpu_scaling_factor, 2)}")
    IO.puts("  Vulkan: #{Float.round(vulkan_scaling_factor, 2)}")
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
