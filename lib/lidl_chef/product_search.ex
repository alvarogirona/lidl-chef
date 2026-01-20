defmodule LidlChef.ProductSearch do
  @moduledoc """
  Product search functionality with metadata enrichment.

  Handles searching products via the RAG system and enriching
  chunk results with document metadata.
  """

  alias LidlChef.{Products, Repo}
  import Ecto.Query

  @doc """
  Searches for products and enriches results with metadata.

  ## Options

    * `:limit` - Maximum number of results (default: 20)
    * `:graph` - Enable GraphRAG search (default: false)
    * `:mode` - Search mode `:semantic`, `:fulltext`, or `:hybrid` (default: :hybrid)

  ## Examples

      iex> LidlChef.ProductSearch.search("croissant")
      {:ok, [%{metadata: %{"title" => "Croissant brioche", ...}, ...}]}

  """
  @spec search(String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    graph = Keyword.get(opts, :graph, false)
    mode = Keyword.get(opts, :mode, :hybrid)

    case Products.search(query, graph: graph, limit: limit, mode: mode) do
      {:ok, chunks} ->
        enriched = enrich_chunks_with_metadata(chunks)
        {:ok, enriched}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Enriches chunks with document metadata.

  Takes a list of chunks and loads their associated document metadata
  in a single efficient query.

  ## Examples

      iex> chunks = [%{document_id: id1}, %{document_id: id2}]
      iex> LidlChef.ProductSearch.enrich_chunks_with_metadata(chunks)
      [%{document_id: id1, metadata: %{...}}, ...]

  """
  @spec enrich_chunks_with_metadata(list(map())) :: list(map())
  def enrich_chunks_with_metadata(chunks) when is_list(chunks) do
    # Get all unique document IDs (already in binary UUID format)
    doc_ids =
      chunks
      |> Enum.map(& &1.document_id)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(doc_ids) do
      # Return chunks with nil metadata if no document IDs
      Enum.map(chunks, &Map.put(&1, :metadata, nil))
    else
      # Fetch all documents at once
      documents = fetch_documents_by_ids(doc_ids)

      # Enrich chunks with document metadata
      Enum.map(chunks, fn chunk ->
        doc = Map.get(documents, chunk.document_id)
        Map.put(chunk, :metadata, doc && doc.metadata)
      end)
    end
  end

  defp fetch_documents_by_ids([]), do: %{}

  defp fetch_documents_by_ids(doc_ids) do
    # Convert binary UUIDs to string format for the query
    # Keep a mapping from original binary to string for building the result map
    id_mapping =
      doc_ids
      |> Enum.map(fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid_string} -> {id, uuid_string}
          :error -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    string_ids = Enum.map(id_mapping, fn {_bin, str} -> str end)

    if string_ids == [] do
      %{}
    else
      # Query returns IDs as strings (Ecto loads :binary_id as string)
      docs_by_string_id =
        from(d in Arcana.Document,
          where: fragment("?::text = ANY(?)", d.id, ^string_ids),
          select: %{id: d.id, metadata: d.metadata}
        )
        |> Repo.all()
        |> Map.new(fn doc -> {doc.id, doc} end)

      # Build final map with binary UUID keys (to match chunk.document_id)
      id_mapping
      |> Enum.map(fn {bin_id, str_id} ->
        {bin_id, Map.get(docs_by_string_id, str_id)}
      end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end
  end
end
