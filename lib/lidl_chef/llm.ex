defmodule LidlChef.LLM do
  @moduledoc """
  LLM client for connecting to LM Studio running locally.

  Uses the OpenAI-compatible API provided by LM Studio at http://127.0.0.1:1234
  with the qwen/qwen3-next-80b model.
  """

  @base_url "http://127.0.0.1:1234"
  @model "qwen/qwen3-30b-a3b-2507"
  @default_timeout 300_000

  @doc """
  Complete a prompt using the local LM Studio LLM.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.
  """
  @spec complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    model = Keyword.get(opts, :model, @model)
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 4096 * 4)

    body = %{
      model: model,
      messages: [
        %{role: "user", content: prompt}
      ],
      temperature: temperature,
      max_tokens: max_tokens
    }

    case Req.post("#{@base_url}/v1/chat/completions",
           json: body,
           receive_timeout: timeout,
           pool_timeout: timeout,
           connect_options: [timeout: timeout]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        response =
          body
          |> Map.get("choices", [])
          |> List.first()
          |> get_in(["message", "content"])

        if response do
          {:ok, response}
        else
          {:error, :no_response_content}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Complete a prompt with a system message for more contextual responses.
  """
  @spec complete_with_system(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def complete_with_system(system_prompt, user_prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    model = Keyword.get(opts, :model, @model)
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    body = %{
      model: model,
      messages: [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_prompt}
      ],
      temperature: temperature,
      max_tokens: max_tokens
    }

    case Req.post("#{@base_url}/v1/chat/completions",
           json: body,
           receive_timeout: timeout,
           pool_timeout: timeout,
           connect_options: [timeout: timeout]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        response =
          body
          |> Map.get("choices", [])
          |> List.first()
          |> get_in(["message", "content"])

        if response do
          {:ok, response}
        else
          {:error, :no_response_content}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if LM Studio is available and responding.
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
  List available models from LM Studio.
  """
  @spec list_models() :: {:ok, list(map())} | {:error, term()}
  def list_models do
    case Req.get("#{@base_url}/v1/models", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: %{"data" => models}}} ->
        {:ok, models}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
