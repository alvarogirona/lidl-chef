defmodule LidlChef.LLM do
  require Logger

  @moduledoc """
  LLM client for connecting to LM Studio running locally.

  Uses the OpenAI-compatible API provided by LM Studio.
  Model, base URL and timeout are read from `config :lidl_chef, :llm`.
  """

  defp llm_cfg, do: Application.get_env(:lidl_chef, :llm, [])
  defp base_url, do: Keyword.get(llm_cfg(), :base_url, "http://127.0.0.1:1234")
  defp default_model, do: Keyword.get(llm_cfg(), :model, "qwen/qwen3-4b-2507")
  defp default_timeout, do: Keyword.get(llm_cfg(), :timeout, 600_000)

  defp req_opts(extra) do
    timeout = default_timeout()

    [
      base_url: "#{base_url()}/v1",
      req_http_options: [receive_timeout: timeout, pool_timeout: timeout]
    ]
    |> Keyword.merge(extra)
  end

  @doc """
  Complete a prompt using the local LM Studio LLM.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.
  """
  @spec complete(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, default_model())
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 4096 * 4)

    case ReqLLM.generate_text("openai:" <> model, prompt,
           req_opts(temperature: temperature, max_tokens: max_tokens)
         ) do
      {:ok, response} ->
        case ReqLLM.Response.text(response) do
          nil -> {:error, :no_response_content}
          text -> {:ok, text}
        end

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
    timeout = Keyword.get(opts, :timeout, default_timeout())
    model = Keyword.get(opts, :model, default_model())
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 4096 * 4)
    system_prompt = Keyword.get(opts, :system_prompt)

    model_spec = "openai:" <> model

    req_http_options =
      [receive_timeout: timeout, pool_timeout: timeout]
      |> Keyword.merge(Keyword.get(opts, :req_http_options, []))

    stream_opts =
      [
        temperature: temperature,
        max_tokens: max_tokens,
        base_url: "#{base_url()}/v1",
        req_http_options: req_http_options,
        receive_timeout: timeout,
        pool_timeout: timeout
      ]
      |> maybe_put_system_prompt(system_prompt)

    case ReqLLM.stream_text(model_spec, prompt, stream_opts) do
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
    model = Keyword.get(opts, :model, default_model())
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    case ReqLLM.generate_text("openai:" <> model, user_prompt,
           req_opts(
             temperature: temperature,
             max_tokens: max_tokens,
             system_prompt: system_prompt
           )
         ) do
      {:ok, response} ->
        case ReqLLM.Response.text(response) do
          nil -> {:error, :no_response_content}
          text -> {:ok, text}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if LM Studio is available and responding.
  """
  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    case Req.get("#{base_url()}/v1/models", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_system_prompt(opts, nil), do: opts
  defp maybe_put_system_prompt(opts, system_prompt), do: Keyword.put(opts, :system_prompt, system_prompt)
end
