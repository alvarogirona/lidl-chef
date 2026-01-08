require Logger

question =
  "En mi nevera tengo tomates, zanahoria, tofu, queso, carne de ternera, carne de pollo. Puedes sugerirme alguna receta que tenga algunos de estos ingredientes?"

IO.puts("\n===== TESTING INGREDIENT QUERY =====")
IO.puts("Question: #{question}\n")

# First, let's see what the raw search returns
IO.puts("\n1. Testing quick_search (what works on /recipes):")

{:ok, quick_results} =
  LidlChef.RecipeAssistant.quick_search("tomates zanahoria tofu queso ternera pollo", limit: 10)

IO.puts("   Found #{length(quick_results)} results")

Enum.take(quick_results, 3)
|> Enum.each(fn chunk ->
  # Extract recipe name from text
  text_preview = String.slice(chunk.text, 0, 100)
  IO.puts("   - #{text_preview}...")
end)

# Now let's test what happens with Agent.search
IO.puts("\n2. Testing Agent.search directly:")
alias Arcana.Agent
alias LidlChef.{Recipes, Repo}

ctx =
  Agent.new(question, repo: Repo)
  |> Agent.expand()
  |> Agent.search(collection: Recipes.collection_name(), limit: 10, graph: false)

all_chunks = ctx.results |> Enum.flat_map(& &1.chunks) |> Enum.uniq_by(& &1.id)
IO.puts("   Agent.search found #{length(all_chunks)} chunks")

if length(all_chunks) > 0 do
  IO.puts("\n   First 3 chunk texts:")

  Enum.take(all_chunks, 3)
  |> Enum.each(fn chunk ->
    text_preview = String.slice(chunk.text, 0, 100)
    IO.puts("   - #{text_preview}...")
  end)
else
  IO.puts("   ⚠️  NO CHUNKS FOUND!")
end

# Now let's test the full pipeline
IO.puts("\n3. Testing full RAG pipeline:")
result = LidlChef.RecipeAssistant.ask(question)

case result do
  {:ok, answer} ->
    IO.puts("   ✅ Got answer (#{String.length(answer)} chars)")
    IO.puts("\n===== ANSWER =====")
    IO.puts(answer)
    IO.puts("==================\n")

  {:error, reason} ->
    IO.puts("   ❌ Error: #{inspect(reason)}")
end
