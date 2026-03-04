defmodule LidlChef.Embedder do
  @moduledoc """
  Custom embedder client for connecting to LM Studio running locally.

  Uses the OpenAI-compatible embedding API provided by LM Studio at http://127.0.0.1:1234
  with the text-embedding-qwen3-embedding-0.6b model (1024 dimensions).

  Implements the `Arcana.Embedder` behaviour for use with Arcana RAG system.
  """

  @behaviour Arcana.Embedder

  @base_url "http://127.0.0.1:1234"
  @model "text-embedding-qwen3-embedding-0.6b"
  @default_timeout 120_000

  @doc """
  Generate an embedding for the given text using the local LM Studio embedding model.

  Returns `{:ok, [float()]}` on success or `{:error, reason}` on failure.
  """
  @impl Arcana.Embedder
  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, _opts \\ []) do
    body = %{
      model: @model,
      input: text
    }

    case Req.post("#{@base_url}/v1/embeddings",
           json: body,
           receive_timeout: @default_timeout,
           pool_timeout: @default_timeout,
           connect_options: [timeout: @default_timeout]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        embedding =
          body
          |> Map.get("data", [])
          |> List.first()
          |> case do
            %{"embedding" => embedding} when is_list(embedding) -> {:ok, embedding}
            _ -> {:error, :no_embedding_in_response}
          end

        embedding

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate embeddings for multiple texts in a single batch request.

  Returns `{:ok, [[float()]]}` on success or `{:error, reason}` on failure.
  """
  @impl Arcana.Embedder
  @spec embed_batch([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed_batch(texts, _opts \\ []) when is_list(texts) do
    body = %{
      model: @model,
      input: texts
    }

    case Req.post("#{@base_url}/v1/embeddings",
           json: body,
           receive_timeout: @default_timeout,
           pool_timeout: @default_timeout,
           connect_options: [timeout: @default_timeout]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        embeddings =
          body
          |> Map.get("data", [])
          |> Enum.sort_by(&Map.get(&1, "index", 0))
          |> Enum.map(&Map.get(&1, "embedding"))

        if Enum.all?(embeddings, &is_list/1) do
          {:ok, embeddings}
        else
          {:error, :invalid_embeddings_in_response}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if the embedding service is available and responding.
  """
  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    case Req.get("#{@base_url}/v1/models", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the embedding dimensions for the configured model.
  """
  @impl Arcana.Embedder
  @spec dimensions(keyword()) :: pos_integer()
  def dimensions(_opts \\ []), do: 1024
end
