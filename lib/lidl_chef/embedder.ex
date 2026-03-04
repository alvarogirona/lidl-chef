defmodule LidlChef.Embedder do
  @moduledoc """
  Embedder client for connecting to LM Studio running locally.

  Uses the OpenAI-compatible embedding API provided by LM Studio.
  Model, base URL and timeout are read from `config :lidl_chef, :embedder`.

  Implements the `Arcana.Embedder` behaviour for use with the Arcana RAG system.
  """

  @behaviour Arcana.Embedder

  defp embedder_cfg, do: Application.get_env(:lidl_chef, :embedder, [])
  defp base_url, do: Keyword.get(embedder_cfg(), :base_url, "http://127.0.0.1:1234")
  defp default_model, do: Keyword.get(embedder_cfg(), :model, "text-embedding-qwen3-embedding-0.6b")
  defp default_timeout, do: Keyword.get(embedder_cfg(), :timeout, 120_000)

  defp model_spec, do: "openai:" <> default_model()

  defp req_opts do
    timeout = default_timeout()

    [
      base_url: "#{base_url()}/v1",
      req_http_options: [receive_timeout: timeout, pool_timeout: timeout]
    ]
  end

  @doc """
  Generate an embedding for the given text using the local LM Studio embedding model.

  Returns `{:ok, [float()]}` on success or `{:error, reason}` on failure.
  """
  @impl Arcana.Embedder
  @spec embed(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def embed(text, _opts \\ []) do
    ReqLLM.Embedding.embed(model_spec(), text, req_opts())
  end

  @doc """
  Generate embeddings for multiple texts in a single batch request.

  Returns `{:ok, [[float()]]}` on success or `{:error, reason}` on failure.
  """
  @impl Arcana.Embedder
  @spec embed_batch([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed_batch(texts, _opts \\ []) when is_list(texts) do
    ReqLLM.Embedding.embed(model_spec(), texts, req_opts())
  end

  @doc """
  Check if the embedding service is available and responding.
  """
  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    case Req.get("#{base_url()}/v1/models", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Arcana.Embedder
  @spec dimensions(keyword()) :: pos_integer()
  def dimensions(_opts \\ []), do: 1024
end
