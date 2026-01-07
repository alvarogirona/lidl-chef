# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     LidlChef.Repo.insert!(%LidlChef.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Optionally load a small subset of recipes for development
# To load all recipes, use: mix lidl_chef.load_recipes

IO.puts("Seeds file ready. Run 'mix lidl_chef.load_recipes' to load the recipe dataset.")
