question = "Dame 3 recetas que lleven tofu"

# Using the Phoenix app context
{:ok, answer} = LidlChef.RecipeAssistant.ask(question)
IO.puts("\n\n===== RESPUESTA =====")
IO.puts(answer)
IO.puts("=====================\n\n")

# Check for duplicates
urls =
  Regex.scan(~r/https:\/\/recetas\.lidl\.es\/[^\s)]+/, answer)
  |> Enum.map(fn [url] -> url end)

IO.puts("URLs encontradas:")
Enum.each(urls, &IO.puts("  - #{&1}"))

if length(urls) != length(Enum.uniq(urls)) do
  IO.puts("\n⚠️  WARNING: Se encontraron URLs duplicadas!")
else
  IO.puts("\n✅ Todas las URLs son únicas")
end
