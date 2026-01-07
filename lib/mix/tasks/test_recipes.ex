defmodule Mix.Tasks.TestRecipes do
  @moduledoc """
  Test recipe search functionality.
  """
  use Mix.Task

  @shortdoc "Test the recipe search system"

  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:lidl_chef)

    IO.puts("\n=== Testing Recipe Search System ===\n")

    # Test basic search
    IO.puts("🔍 Testing basic recipe search...")
    try do
      {:ok, results} = LidlChef.Recipes.search("pasta with vegetables", graph: false, limit: 3)

      IO.puts("✅ Found #{length(results)} recipes")

      Enum.with_index(results, 1)
      |> Enum.each(fn {result, idx} ->
        recipe_text = result.text |> String.split("\n") |> Enum.take(3) |> Enum.join(" ")
        IO.puts("  #{idx}. #{String.slice(recipe_text, 0, 80)}...")
      end)
    rescue
      e -> IO.puts("❌ Search failed: #{inspect(e)}")
    end

    # Test direct Arcana search without GraphRAG
    IO.puts("\n🔍 Testing direct Arcana search...")
    try do
      {:ok, results} = Arcana.search("chicken recipes",
        repo: LidlChef.Repo,
        collection: "lidl_recipes",
        limit: 3,
        mode: :semantic
      )

      IO.puts("✅ Found #{length(results)} recipes via direct search")

      Enum.with_index(results, 1)
      |> Enum.each(fn {result, idx} ->
        recipe_text = result.text |> String.split("\n") |> Enum.take(3) |> Enum.join(" ")
        IO.puts("  #{idx}. #{String.slice(recipe_text, 0, 80)}...")
      end)
    rescue
      e -> IO.puts("❌ Direct search failed: #{inspect(e)}")
    end

    # Test LLM connectivity through RecipeAssistant
    IO.puts("\n🤖 Testing LLM connectivity...")
    try do
      {:ok, response} = LidlChef.RecipeAssistant.ask("What is a simple pasta recipe?")
      if String.length(response) > 0 do
        IO.puts("✅ LLM is working: #{String.slice(response, 0, 100)}...")
      else
        IO.puts("⚠️  LLM returned empty response")
      end
    rescue
      e -> IO.puts("❌ LLM failed: #{inspect(e)}")
    end

    # Test database connection
    IO.puts("\n📊 Testing database stats...")
    try do
      collection = Arcana.Collection.get_or_create!("lidl_recipes", repo: LidlChef.Repo)
      documents = Arcana.Document.list_by_collection(collection.id, repo: LidlChef.Repo)
      chunks = Arcana.Chunk.count_by_collection(collection.id, repo: LidlChef.Repo)

      IO.puts("✅ Database stats:")
      IO.puts("  - Documents: #{length(documents)}")
      IO.puts("  - Total chunks: #{chunks}")
      IO.puts("  - Collection: #{collection.name}")
    rescue
      e -> IO.puts("❌ Database check failed: #{inspect(e)}")
    end

    IO.puts("\n=== Test Complete ===")
  end
end
