defmodule Mix.Tasks.TestWeeklyMenu do
  @moduledoc """
  Focused test for weekly menu generation (7 days).

  This test helps debug and fix issues with weekly menu planning
  by testing various formulations of 7-day menu requests.

  ## Usage

      mix test_weekly_menu              # Run all weekly menu tests
      mix test_weekly_menu --verbose    # Show full responses and debug info

  """

  use Mix.Task
  alias LidlChef.RecipeAssistant
  require Logger

  @shortdoc "Test weekly menu generation (7 days)"

  @impl Mix.Task
  def run(args) do
    # Start the application
    Mix.Task.run("app.start")

    opts = parse_args(args)
    verbose = Keyword.get(opts, :verbose, false)

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("🧪 Weekly Menu Generation Test (7 Days)")
    IO.puts(String.duplicate("=", 70) <> "\n")

    results = run_weekly_menu_tests(verbose)

    print_summary(results)
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [verbose: :boolean],
        aliases: [v: :verbose]
      )

    opts
  end

  # Test cases for 7-day menus with different phrasings
  defp run_weekly_menu_tests(verbose) do
    tests = [
      {
        "7-day menu - Spanish (dias)",
        fn ->
          RecipeAssistant.ask("Puedes darme un menu semanal de 7 dias con 3 comidas por dia?")
        end
      },
      {
        "7-day menu - Spanish (días with accent)",
        fn ->
          RecipeAssistant.ask("Dame un menú semanal de 7 días con desayuno, comida y cena")
        end
      },
      {
        "Weekly menu - Spanish simple",
        fn -> RecipeAssistant.ask("Menú semanal completo para una semana") end
      },
      {
        "Weekly menu - Spanish with family",
        fn -> RecipeAssistant.ask("Planifica un menú semanal para una familia de 4") end
      },
      {
        "Weekly menu - vegetarian",
        fn -> RecipeAssistant.ask("Menú semanal vegetariano de 7 días") end
      },
      {
        "4-day menu (boundary test)",
        fn -> RecipeAssistant.ask("Dame un menú de 4 días con 3 comidas cada día") end
      },
      {
        "3-day menu (should work)",
        fn -> RecipeAssistant.ask("Dame un menú de 3 días con 3 comidas cada día") end
      }
    ]

    Enum.map(tests, fn {name, test_fn} ->
      run_single_test(name, test_fn, verbose)
    end)
  end

  defp run_single_test(name, test_fn, verbose) do
    IO.write("  • #{name}...\n")

    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        case test_fn.() do
          {:ok, answer} ->
            end_time = System.monotonic_time(:millisecond)
            duration = end_time - start_time

            # Extract statistics from the response
            stats = analyze_response(answer)

            if verbose do
              IO.puts("\n" <> String.duplicate("-", 60))
              IO.puts("Response (#{duration}ms):")
              IO.puts("  Unique recipes: #{stats.unique_recipes}")
              IO.puts("  Days mentioned: #{stats.days_mentioned}")
              IO.puts("  Meals mentioned: #{stats.meals_mentioned}")
              IO.puts("  Has failure message: #{stats.has_failure_message}")
              IO.puts(String.duplicate("-", 60))
              IO.puts(String.slice(answer, 0, 3000))
              if String.length(answer) > 3000, do: IO.puts("... [truncated]")
              IO.puts(String.duplicate("-", 60))
            end

            validation = validate_weekly_menu(answer, stats)

            case validation do
              :ok ->
                IO.puts(
                  "    ✅ PASSED (#{duration}ms) - #{stats.unique_recipes} recipes, #{stats.days_mentioned} days"
                )

                {:passed, name, duration, stats}

              {:error, reason} ->
                IO.puts("    ❌ FAILED - #{reason}")

                IO.puts(
                  "       Stats: #{stats.unique_recipes} recipes, #{stats.days_mentioned} days, meals: #{stats.meals_mentioned}"
                )

                if stats.has_failure_message do
                  IO.puts("       ⚠️  Response contains 'No pude encontrar' message")
                end

                if not verbose do
                  IO.puts("       Preview: #{String.slice(answer, 0, 200)}...")
                end

                {:failed, name, reason, stats}
            end

          {:error, error} ->
            IO.puts("    ❌ ERROR - #{inspect(error)}")
            {:error, name, error, nil}
        end
      rescue
        e ->
          IO.puts("    ❌ EXCEPTION - #{Exception.message(e)}")
          {:error, name, e, nil}
      end

    IO.puts("")
    result
  end

  defp analyze_response(answer) do
    # Count unique recipe URLs
    urls =
      Regex.scan(~r{https://recetas\.lidl\.es/recetas/[^\s\)\]]+}, answer)
      |> Enum.map(&hd/1)
      |> Enum.uniq()

    # Count day keywords
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
      "sunday",
      "día 1",
      "día 2",
      "día 3",
      "día 4",
      "día 5",
      "día 6",
      "día 7"
    ]

    days_found =
      Enum.count(day_keywords, fn day ->
        String.contains?(String.downcase(answer), day)
      end)

    # Count meal types
    meal_keywords = ["desayuno", "breakfast", "comida", "almuerzo", "lunch", "cena", "dinner"]

    meals_found =
      Enum.count(meal_keywords, fn meal ->
        String.contains?(String.downcase(answer), meal)
      end)

    # Check for failure messages
    has_failure =
      String.contains?(answer, [
        "No pude encontrar",
        "no encontré",
        "No encontré",
        "couldn't find",
        "no recipes"
      ])

    %{
      unique_recipes: length(urls),
      days_mentioned: days_found,
      meals_mentioned: meals_found,
      has_failure_message: has_failure,
      total_length: String.length(answer)
    }
  end

  defp validate_weekly_menu(_answer, stats) do
    cond do
      stats.has_failure_message ->
        {:error, "Response contains failure message"}

      stats.unique_recipes < 10 ->
        {:error,
         "Too few unique recipes (#{stats.unique_recipes}), expected at least 10 for 7-day menu"}

      stats.days_mentioned < 4 ->
        {:error, "Too few days mentioned (#{stats.days_mentioned}), expected at least 4"}

      stats.total_length < 500 ->
        {:error, "Response too short (#{stats.total_length} chars)"}

      true ->
        :ok
    end
  end

  defp print_summary(results) do
    passed = Enum.count(results, fn {status, _, _, _} -> status == :passed end)
    failed = Enum.count(results, fn {status, _, _, _} -> status == :failed end)
    errors = Enum.count(results, fn {status, _, _, _} -> status == :error end)
    total = length(results)

    IO.puts(String.duplicate("=", 70))
    IO.puts("📊 Test Summary")
    IO.puts(String.duplicate("=", 70))
    IO.puts("  ✅ Passed:  #{passed}/#{total}")
    IO.puts("  ❌ Failed:  #{failed}/#{total}")
    IO.puts("  💥 Errors:  #{errors}/#{total}")

    if passed == total do
      IO.puts("\n🎉 All weekly menu tests passed!")
    else
      IO.puts("\n⚠️  Some tests failed.")

      # Detailed failure analysis
      failures = Enum.filter(results, fn {status, _, _, _} -> status in [:failed, :error] end)

      if length(failures) > 0 do
        IO.puts("\n📋 Failed tests analysis:")

        Enum.each(failures, fn
          {:failed, name, reason, stats} when not is_nil(stats) ->
            IO.puts("\n  ❌ #{name}")
            IO.puts("     Reason: #{reason}")
            IO.puts("     Recipes found: #{stats.unique_recipes}")
            IO.puts("     Days found: #{stats.days_mentioned}")
            IO.puts("     Meals found: #{stats.meals_mentioned}")

          {:failed, name, reason, _} ->
            IO.puts("\n  ❌ #{name}")
            IO.puts("     Reason: #{reason}")

          {:error, name, error, _} ->
            IO.puts("\n  💥 #{name}")
            IO.puts("     Error: #{inspect(error)}")
        end)
      end

      IO.puts("\n💡 Tip: Run with --verbose to see full responses and debug info")
    end

    IO.puts("")
  end
end
