defmodule LidlChef.LLM do
  require Logger

  @moduledoc """
  LLM client for connecting to LM Studio running locally.

  Uses the OpenAI-compatible API provided by LM Studio at http://127.0.0.1:1234
  with the qwen/qwen3-next-80b model.
  """
  @base_url "http://127.0.0.1:1234"
  @model "qwen/qwen3-4b-2507"
  @default_timeout 600_000

  defp req_client do
    Req.new(
      base_url: @base_url,
      receive_timeout: @default_timeout,
      pool_timeout: @default_timeout,
      retry: false
    )
  end

  @doc """
  Complete a prompt using the local LM Studio LLM.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.
  """
  @spec complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) do
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

    case Req.post(req_client(), url: "/v1/chat/completions", json: body) do
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
  Stream a prompt using the local LM Studio LLM.

  Invokes `on_chunk` for each streamed token and returns the full text on success.
  """
  @spec stream(String.t(), (String.t() -> any()), keyword()) :: {:ok, String.t()} | {:error, term()}
  def stream(prompt, on_chunk, opts \\ []) when is_function(on_chunk, 1) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    model = Keyword.get(opts, :model, @model)
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 4096 * 4)
    system_prompt = Keyword.get(opts, :system_prompt)

    ensure_llmdb_loaded()
    model_spec = "openai:" <> model

    log_model_lookup(model_spec)
    log_provider_models()

    req_http_options =
      [
        receive_timeout: timeout,
        pool_timeout: timeout
      ]
      |> Keyword.merge(Keyword.get(opts, :req_http_options, []))

    api_key = Keyword.get(opts, :api_key, "lm-studio")

    req_opts =
      [
        api_key: api_key,
        temperature: temperature,
        max_tokens: max_tokens,
        base_url: "#{@base_url}/v1",
        req_http_options: req_http_options,
        receive_timeout: timeout,
        pool_timeout: timeout
      ]
      |> maybe_put_system_prompt(system_prompt)

    case ReqLLM.stream_text(model_spec, prompt, req_opts) do
      {:ok, stream_response} ->
        text =
          stream_response
          |> ReqLLM.StreamResponse.tokens()
          |> Enum.reduce("", fn token, acc ->
            on_chunk.(token)
            acc <> token
          end)

        {:ok, text}

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

    case Req.post(req_client(), url: "/v1/chat/completions", json: body) do
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

  defp maybe_put_system_prompt(opts, nil), do: opts
  defp maybe_put_system_prompt(opts, system_prompt), do: Keyword.put(opts, :system_prompt, system_prompt)

  defp log_model_lookup(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} ->
        Logger.info("ReqLLM model resolved: #{model_spec} -> #{inspect(model)}")

      {:error, reason} ->
        Logger.warning("ReqLLM model not found: #{model_spec} (#{inspect(reason)}). Reloading LLMDB...")

        case LLMDB.load(custom: custom_llmdb_models()) do
          {:ok, _snapshot} ->
            Logger.info("LLMDB reloaded for model lookup")

            case ReqLLM.model(model_spec) do
              {:ok, model} ->
                Logger.info("ReqLLM model resolved after reload: #{model_spec} -> #{inspect(model)}")

              {:error, reload_reason} ->
                Logger.warning(
                  "ReqLLM model still not found after reload: #{model_spec} (#{inspect(reload_reason)})"
                )
            end

          {:error, load_reason} ->
            Logger.warning("LLMDB reload failed: #{inspect(load_reason)}")
        end
    end
  end

  defp log_provider_models do
    case list_models() do
      {:ok, models} ->
        names = Enum.map(models, &Map.get(&1, "id"))
        Logger.info("LM Studio models from #{@base_url}/v1: #{inspect(names)}")

      {:error, reason} ->
        Logger.warning("LM Studio model list failed: #{inspect(reason)}")
    end
  end

  defp ensure_llmdb_loaded do
    case LLMDB.Store.snapshot() do
      nil ->
        case LLMDB.load(custom: custom_llmdb_models()) do
          {:ok, _snapshot} ->
            Logger.info("LLMDB loaded at runtime")

          {:error, reason} ->
            Logger.warning("LLMDB load failed at runtime: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end

  defp custom_llmdb_models do
    %{
      openai: [
        name: "OpenAI-compatible (LM Studio)",
        models: %{
          "qwen/qwen3-4b-2507" => %{capabilities: %{chat: true, streaming: %{text: true}}},
          "qwen/qwen3-4b-thinking-2507" => %{capabilities: %{chat: true, streaming: %{text: true}}},
          "qwen3-4b-instruct-2507" => %{capabilities: %{chat: true, streaming: %{text: true}}},
          "Qwen3-Next-80B-A3B-Instruct-UD-Q4_K_XL" => %{capabilities: %{chat: true, streaming: %{text: true}}}
        }
      ]
    }
  end
end
