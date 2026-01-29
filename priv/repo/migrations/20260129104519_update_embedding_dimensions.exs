defmodule LidlChef.Repo.Migrations.UpdateEmbeddingDimensions do
  use Ecto.Migration

  def up do
    # Drop the existing HNSW index
    execute "DROP INDEX IF EXISTS arcana_chunks_embedding_idx"

    # Temporarily allow null values
    execute "ALTER TABLE arcana_chunks ALTER COLUMN embedding DROP NOT NULL"

    # Clear existing embeddings (they have wrong dimensions and need to be re-embedded)
    execute "UPDATE arcana_chunks SET embedding = NULL"

    # Alter the embedding column to new dimensions (1024 for qwen3-embedding-0.6b)
    alter table(:arcana_chunks) do
      modify :embedding, :vector, size: 1024, null: true
    end

    # Recreate the HNSW index with the new dimensions
    execute """
    CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
    USING hnsw (embedding vector_cosine_ops)
    """
  end

  def down do
    execute "ALTER TABLE arcana_chunks ALTER COLUMN embedding DROP NOT NULL"

    # Drop the HNSW index
    execute "DROP INDEX IF EXISTS arcana_chunks_embedding_idx"

    # Temporarily allow null values (in case NOT NULL was re-added)
    execute "ALTER TABLE arcana_chunks ALTER COLUMN embedding DROP NOT NULL"

    # Clear embeddings (they need to be re-embedded with the old model)
    execute "UPDATE arcana_chunks SET embedding = NULL"

    # Revert to previous dimensions (384 for bge-small-en-v1.5)
    alter table(:arcana_chunks) do
      modify :embedding, :vector, size: 384, null: true
    end

    # Recreate the HNSW index
    execute """
    CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
    USING hnsw (embedding vector_cosine_ops)
    """
  end
end
