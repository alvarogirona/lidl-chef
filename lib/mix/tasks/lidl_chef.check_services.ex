defmodule Mix.Tasks.LidlChef.CheckServices do
  @moduledoc """
  Check if Arcana services are running properly.
  """
  use Mix.Task

  @shortdoc "Check Arcana services status"

  @impl Mix.Task
  def run(_args) do
    # Start the application
    Mix.Task.run("app.start")

    Mix.shell().info("Checking Arcana services...")

    # Check if the embedding service is alive
    embedder_name = :"Elixir.Arcana.Embedder.Local.BAAI/bge-small-en-v1.5"
    embedder_alive = Process.whereis(embedder_name) != nil

    Mix.shell().info(
      "Embedder process (#{embedder_name}): #{if embedder_alive, do: "✅ Running", else: "❌ Not running"}"
    )

    # Check if NER service is alive
    ner_name = :"Elixir.Arcana.Graph.NERServing.intfloat/e5-small-v2"
    ner_alive = Process.whereis(ner_name) != nil

    Mix.shell().info(
      "NER process (#{ner_name}): #{if ner_alive, do: "✅ Running", else: "❌ Not running"}"
    )

    # Try to test embedder
    Mix.shell().info("Testing embedder...")

    case test_embedder() do
      :ok ->
        Mix.shell().info("✅ Embedder test successful")

      {:error, reason} ->
        Mix.shell().error("❌ Embedder test failed: #{inspect(reason)}")
    end

    # List all registered processes for debugging
    Mix.shell().info("\nAll registered processes:")

    Process.registered()
    |> Enum.filter(&String.contains?(to_string(&1), "Arcana"))
    |> Enum.each(fn name ->
      Mix.shell().info("  - #{name}")
    end)
  end

  defp test_embedder do
    try do
      # Test embedding a simple text
      case Arcana.Embedder.embed(Arcana.Config.embedder(), "test", []) do
        {:ok, _embedding} -> :ok
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, reason -> {:error, {:exit, reason}}
      error -> {:error, error}
    end
  end
end
