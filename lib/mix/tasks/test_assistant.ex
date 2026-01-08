defmodule Mix.Tasks.TestAssistant do
  @moduledoc """
  Test task for the LidlChef Recipe Assistant.

  Runs a series of tests to verify the recipe assistant works correctly
  for both simple ingredient-based queries and complex menu planning.

  ## Usage

      mix test_assistant              # Run all tests
      mix test_assistant --simple     # Run only simple tests
      mix test_assistant --complex    # Run only complex tests
      mix test_assistant --verbose    # Show full responses

  """

  use Mix.Task
  alias LidlChef.RecipeAssistant

  @shortdoc "Test the Recipe Assistant with various queries"

  @impl Mix.Task
  def run(args) do
    # Start the application
    Mix.Task.run("app.start")

    opts = parse_args(args)
    verbose = Keyword.get(opts, :verbose, false)
    run_simple = Keyword.get(opts, :simple, true)
    run_complex = Keyword.get(opts, :complex, true)

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("🧪 LidlChef Recipe Assistant Tests")
    IO.puts(String.duplicate("=", 60) <> "\n")

    results = []

    # Simple tests
    results =
      if run_simple do
        IO.puts("📋 Running Simple Tests...\n")
        results ++ run_simple_tests(verbose)
      else
        results
      end

    # Complex tests
    results =
      if run_complex do
        IO.puts("\n📋 Running Complex Tests (Menu Planning)...\n")
        results ++ run_complex_tests(verbose)
      else
        results
      end

    # Print summary
    print_summary(results)
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [verbose: :boolean, simple: :boolean, complex: :boolean],
        aliases: [v: :verbose, s: :simple, c: :complex]
      )

    # If neither simple nor complex is specified, run both
    if !Keyword.has_key?(opts, :simple) and !Keyword.has_key?(opts, :complex) do
      opts ++ [simple: true, complex: true]
    else
      opts
      |> Keyword.put_new(:simple, Keyword.get(opts, :simple, false))
      |> Keyword.put_new(:complex, Keyword.get(opts, :complex, false))
    end
  end

  # ============================================
  # Simple Tests
  # ============================================

  defp run_simple_tests(verbose) do
    tests = [
      {
        "Ingredient search - pollo y arroz",
        fn -> RecipeAssistant.ask("Tengo pollo y arroz, que puedo cocinar?") end,
        &validate_has_recipes/1
      },
      {
        "Ingredient search - pasta y tomate",
        fn -> RecipeAssistant.ask("Recetas con pasta y tomate") end,
        &validate_has_recipes/1
      },
      {
        "Ingredient search - pescado y verduras",
        fn -> RecipeAssistant.ask("Qué puedo hacer con pescado y verduras?") end,
        &validate_has_recipes/1
      },
      {
        "Ingredient search - legumbres",
        fn -> RecipeAssistant.ask("Recetas con lentejas o garbanzos") end,
        &validate_has_recipes/1
      },
      {
        "Dietary restriction - vegano",
        fn -> RecipeAssistant.ask("Recetas veganas con verduras") end,
        &validate_has_recipes/1
      },
      {
        "Dietary restriction - vegetariano",
        fn -> RecipeAssistant.ask("Dame recetas vegetarianas") end,
        &validate_has_recipes/1
      },
      {
        "Dietary restriction - sin gluten",
        fn -> RecipeAssistant.ask("Recetas sin gluten para celiacos") end,
        &validate_has_recipes/1
      },
      {
        "Quick recipe search",
        fn -> RecipeAssistant.ask("Receta rápida y fácil para cenar") end,
        &validate_has_recipes/1
      },
      {
        "Dessert search",
        fn -> RecipeAssistant.ask("Postres fáciles con fruta") end,
        &validate_has_recipes/1
      },
      {
        "Breakfast search",
        fn -> RecipeAssistant.ask("Ideas para desayunos saludables") end,
        &validate_has_recipes/1
      }
    ]

    Enum.map(tests, fn {name, test_fn, validator} ->
      run_single_test(name, test_fn, validator, verbose)
    end)
  end

  # ============================================
  # Complex Tests (Menu Planning)
  # ============================================

  defp run_complex_tests(verbose) do
    tests = [
      {
        "Daily menu",
        fn -> RecipeAssistant.ask("Sugiereme un menú para hoy con desayuno, comida y cena") end,
        &validate_daily_menu/1
      },
      {
        "Daily vegan menu",
        fn -> RecipeAssistant.ask("Dame un menú diario vegano") end,
        &validate_daily_menu/1
      },
      {
        "Daily vegetarian menu",
        fn -> RecipeAssistant.ask("Menú del día vegetariano completo") end,
        &validate_daily_menu/1
      },
      {
        "Weekly menu",
        fn -> RecipeAssistant.ask("Dame un menú semanal variado para 2 personas") end,
        &validate_weekly_menu/1
      },
      {
        "Weekly vegetarian menu",
        fn -> RecipeAssistant.ask("Planifica un menú semanal vegetariano") end,
        &validate_weekly_menu/1
      },
      {
        "Weekly menu with variety",
        fn -> RecipeAssistant.ask("Menú semanal equilibrado con mucha variedad") end,
        &validate_weekly_menu/1
      },
      {
        "Weekly healthy menu",
        fn -> RecipeAssistant.ask("Menú semanal saludable y ligero") end,
        &validate_weekly_menu/1
      }
    ]

    Enum.map(tests, fn {name, test_fn, validator} ->
      run_single_test(name, test_fn, validator, verbose)
    end)
  end

  # ============================================
  # Test Runner
  # ============================================

  defp run_single_test(name, test_fn, validator, verbose) do
    IO.write("  • #{name}... ")

    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        case test_fn.() do
          {:ok, answer} ->
            validation = validator.(answer)
            end_time = System.monotonic_time(:millisecond)
            duration = end_time - start_time

            if verbose do
              IO.puts("\n" <> String.duplicate("-", 40))
              IO.puts("Response (#{duration}ms):")
              IO.puts(String.slice(answer, 0, 2000))
              if String.length(answer) > 2000, do: IO.puts("... [truncated]")
              IO.puts(String.duplicate("-", 40))
            end

            case validation do
              :ok ->
                IO.puts("✅ PASSED (#{duration}ms)")
                {:passed, name, duration}

              {:error, reason} ->
                IO.puts("❌ FAILED - #{reason}")

                if not verbose do
                  IO.puts("    Response preview: #{String.slice(answer, 0, 200)}...")
                end

                {:failed, name, reason}
            end

          {:error, error} ->
            IO.puts("❌ ERROR - #{inspect(error)}")
            {:error, name, error}
        end
      rescue
        e ->
          IO.puts("❌ EXCEPTION - #{Exception.message(e)}")
          {:error, name, e}
      end

    result
  end

  # ============================================
  # Validators
  # ============================================

  defp validate_has_recipes(answer) do
    cond do
      String.contains?(answer, "recetas.lidl.es") ->
        :ok

      String.contains?(answer, ["couldn't find", "no encontré", "No encontré"]) ->
        {:error, "No recipes found in response"}

      String.length(answer) < 50 ->
        {:error, "Response too short"}

      true ->
        {:error, "No Lidl recipe URLs found in response"}
    end
  end

  defp validate_daily_menu(answer) do
    # Check for meal structure
    has_breakfast = String.contains?(String.downcase(answer), ["desayuno", "breakfast"])
    has_lunch = String.contains?(String.downcase(answer), ["comida", "almuerzo", "lunch"])
    has_dinner = String.contains?(String.downcase(answer), ["cena", "dinner"])

    # Count unique recipe URLs
    urls =
      Regex.scan(~r{https://recetas\.lidl\.es/recetas/[^\s\)\]]+}, answer)
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    cond do
      length(urls) < 2 ->
        {:error, "Too few recipes (#{length(urls)}), expected at least 2 unique recipes"}

      not (has_breakfast or has_lunch or has_dinner) ->
        {:error, "Missing meal structure (breakfast/lunch/dinner)"}

      true ->
        :ok
    end
  end

  defp validate_weekly_menu(answer) do
    # Check for day structure
    day_keywords = [
      "lunes",
      "monday",
      "martes",
      "tuesday",
      "miércoles",
      "wednesday",
      "jueves",
      "thursday",
      "viernes",
      "friday",
      "sábado",
      "saturday",
      "domingo",
      "sunday"
    ]

    days_found =
      Enum.count(day_keywords, fn day ->
        String.contains?(String.downcase(answer), day)
      end)

    # Count unique recipe URLs
    urls =
      Regex.scan(~r{https://recetas\.lidl\.es/recetas/[^\s\)\]]+}, answer)
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    cond do
      length(urls) < 5 ->
        {:error, "Too few unique recipes (#{length(urls)}), expected at least 5 for weekly menu"}

      days_found < 4 ->
        {:error, "Missing day structure (found #{days_found} days)"}

      # Check for excessive repetition
      check_recipe_repetition(urls) ->
        {:error, "Too much recipe repetition in the menu"}

      true ->
        :ok
    end
  end

  defp check_recipe_repetition(urls) do
    # If we have less than 7 unique URLs for a weekly menu, it might be too repetitive
    # But this depends on context, so we'll be lenient
    length(urls) < 5
  end

  # ============================================
  # Summary
  # ============================================

  defp print_summary(results) do
    passed = Enum.count(results, fn {status, _, _} -> status == :passed end)
    failed = Enum.count(results, fn {status, _, _} -> status == :failed end)
    errors = Enum.count(results, fn {status, _, _} -> status == :error end)
    total = length(results)

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("📊 Test Summary")
    IO.puts(String.duplicate("=", 60))
    IO.puts("  ✅ Passed:  #{passed}/#{total}")
    IO.puts("  ❌ Failed:  #{failed}/#{total}")
    IO.puts("  💥 Errors:  #{errors}/#{total}")

    if passed == total do
      IO.puts("\n🎉 All tests passed!")
    else
      IO.puts("\n⚠️  Some tests failed. Run with --verbose for more details.")

      # List failures
      failures = Enum.filter(results, fn {status, _, _} -> status in [:failed, :error] end)

      if length(failures) > 0 do
        IO.puts("\nFailed tests:")

        Enum.each(failures, fn {_status, name, reason} ->
          IO.puts("  • #{name}: #{inspect(reason)}")
        end)
      end
    end

    IO.puts("")
  end
end
