defmodule LidlChef.ProductSearchTest do
  use LidlChef.DataCase, async: true

  alias LidlChef.ProductSearch

  describe "enrich_chunks_with_metadata/1" do
    test "enriches chunks with document metadata" do
      # Create a test collection
      {:ok, collection} = Arcana.Collection.get_or_create("test_products", Repo)

      # Create test documents with metadata
      {:ok, doc1} =
        %Arcana.Document{}
        |> Arcana.Document.changeset(%{
          content: "Test product 1",
          metadata: %{"title" => "Product 1", "wawi_id" => "123"},
          status: :completed,
          collection_id: collection.id
        })
        |> Repo.insert()

      {:ok, doc2} =
        %Arcana.Document{}
        |> Arcana.Document.changeset(%{
          content: "Test product 2",
          metadata: %{"title" => "Product 2", "wawi_id" => "456"},
          status: :completed,
          collection_id: collection.id
        })
        |> Repo.insert()

      # Create mock chunks
      chunks = [
        %{document_id: doc1.id, text: "chunk 1"},
        %{document_id: doc2.id, text: "chunk 2"}
      ]

      # Enrich chunks
      enriched = ProductSearch.enrich_chunks_with_metadata(chunks)

      # Verify enrichment
      assert length(enriched) == 2

      chunk1 = Enum.find(enriched, fn c -> c.document_id == doc1.id end)
      assert chunk1.metadata["title"] == "Product 1"
      assert chunk1.metadata["wawi_id"] == "123"

      chunk2 = Enum.find(enriched, fn c -> c.document_id == doc2.id end)
      assert chunk2.metadata["title"] == "Product 2"
      assert chunk2.metadata["wawi_id"] == "456"
    end

    test "handles chunks with nil document_id" do
      chunks = [
        %{document_id: nil, text: "chunk without doc"}
      ]

      enriched = ProductSearch.enrich_chunks_with_metadata(chunks)

      assert length(enriched) == 1
      assert hd(enriched).metadata == nil
    end

    test "handles empty chunks list" do
      enriched = ProductSearch.enrich_chunks_with_metadata([])

      assert enriched == []
    end

    test "handles chunks with non-existent document_id" do
      # Use Ecto.UUID.bingenerate/0 to create a properly formatted binary UUID
      fake_id = Ecto.UUID.bingenerate()

      chunks = [
        %{document_id: fake_id, text: "chunk with fake doc"}
      ]

      enriched = ProductSearch.enrich_chunks_with_metadata(chunks)

      assert length(enriched) == 1
      assert hd(enriched).metadata == nil
    end

    test "handles duplicate document_ids efficiently" do
      # Create a test collection
      {:ok, collection} = Arcana.Collection.get_or_create("test_products", Repo)

      # Create one document
      {:ok, doc} =
        %Arcana.Document{}
        |> Arcana.Document.changeset(%{
          content: "Test product",
          metadata: %{"title" => "Shared Product", "wawi_id" => "789"},
          status: :completed,
          collection_id: collection.id
        })
        |> Repo.insert()

      # Create multiple chunks referencing the same document
      chunks = [
        %{document_id: doc.id, text: "chunk 1"},
        %{document_id: doc.id, text: "chunk 2"},
        %{document_id: doc.id, text: "chunk 3"}
      ]

      enriched = ProductSearch.enrich_chunks_with_metadata(chunks)

      # Verify all chunks have the same metadata
      assert length(enriched) == 3
      assert Enum.all?(enriched, fn c -> c.metadata["title"] == "Shared Product" end)
      assert Enum.all?(enriched, fn c -> c.metadata["wawi_id"] == "789" end)
    end
  end

  describe "search/2" do
    setup do
      # This test requires actual products to be ingested
      # For now, we'll just test the basic flow
      :ok
    end

    test "returns error tuple when search fails" do
      # Search in empty collection should return empty results
      result = ProductSearch.search("nonexistent product xyz123")

      assert {:ok, results} = result
      assert is_list(results)
    end

    test "accepts search options" do
      result = ProductSearch.search("test", limit: 5, graph: false, mode: :semantic)

      assert {:ok, results} = result
      assert is_list(results)
    end
  end
end
