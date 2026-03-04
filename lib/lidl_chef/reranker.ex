defmodule LidlChef.Reranker do
  @moduledoc """
  Custom reranker using the smaller qwen3-reranker-0.6b model.

  This reranker uses a lightweight model specifically optimized for reranking tasks,
  with a custom prompt designed for recipe ranking based on ingredients and user preferences.

  ## Options

  - `:threshold` - Minimum score for a chunk to be included (default from config)
  - `:concurrency` - Max parallel requests to LLM server (default: 10)
  - `:base_url` - Base URL for the LLM server (default from config)
  """

  @behaviour Arcana.Agent.Reranker
  require Logger

  defp reranker_cfg, do: Application.get_env(:lidl_chef, :reranker, [])
  defp default_base_url, do: Keyword.get(reranker_cfg(), :base_url, "http://127.0.0.1:1234")
  defp default_model, do: Keyword.get(reranker_cfg(), :model, "qwen3-reranker-0.6b")
  defp default_threshold, do: Keyword.get(reranker_cfg(), :threshold, 5)
  defp default_timeout, do: Keyword.get(reranker_cfg(), :timeout, :infinity)

  # Qwen3 reranker models use chain-of-thought reasoning
  # The model thinks in reasoning_content and outputs final answer in content
  @recipe_prompt_template """
  <query>
  {question}
  </query>
  <document>
  {chunk_text}
  </document>

  Rate how well this recipe matches the user's request for recipe suggestions.
  Consider:
  - Does the recipe use ingredients mentioned by the user?
  - Does it match dietary preferences if mentioned?
  - A recipe does NOT need ALL ingredients - using SOME of them is a good match

  Score (0-10):
  - 10: Perfect match, uses mentioned ingredients/preferences
  - 7-9: Good match, uses most mentioned ingredients
  - 4-6: Partial match, uses some mentioned ingredients
  - 1-3: Weak match, minimal relevance
  - 0: Not relevant at all

  Output ONLY a single integer 0-10.
  """

  @impl Arcana.Agent.Reranker
  def rerank(_question, [], _opts), do: {:ok, []}

  def rerank(question, chunks, opts) do
    threshold = Keyword.get(opts, :threshold, default_threshold())
    concurrency = Keyword.get(opts, :concurrency, 10)
    base_url = Keyword.get(opts, :base_url, default_base_url())

    Logger.info(
      "[Reranker] Received #{length(chunks)} chunks to rerank (concurrency: #{concurrency}, base_url: #{base_url})"
    )

    start_time = System.monotonic_time(:millisecond)

    scored_chunks =
      chunks
      |> Task.async_stream(
        fn chunk ->
          request_start = System.monotonic_time(:millisecond)
          prompt = build_prompt(question, chunk.text)
          score = get_score(prompt, base_url)
          request_duration = System.monotonic_time(:millisecond) - request_start
          Logger.debug("[Reranker] Score #{score} (#{request_duration}ms)")
          {chunk, score}
        end,
        max_concurrency: concurrency,
        timeout: default_timeout(),
        ordered: false
      )
      |> Enum.reduce([], fn
        {:ok, result}, acc ->
          [result | acc]

        {:exit, reason}, acc ->
          Logger.error("[Reranker] Task failed: #{inspect(reason)}")
          acc
      end)
      |> Enum.filter(fn {_chunk, score} -> score >= threshold end)
      |> Enum.sort_by(fn {_chunk, score} -> score end, :desc)
      |> Enum.map(fn {chunk, _score} -> chunk end)

    total_duration = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "[Reranker] Returned #{length(scored_chunks)} chunks after reranking (total: #{total_duration}ms)"
    )

    {:ok, scored_chunks}
  end

  defp build_prompt(question, chunk_text) do
    @recipe_prompt_template
    |> String.replace("{question}", question)
    |> String.replace("{chunk_text}", chunk_text)
  end

  defp get_score(prompt, base_url) do
    model = default_model()
    timeout = default_timeout()
    model_spec = "openai:" <> model

    req_opts = [
      base_url: "#{base_url}/v1",
      temperature: 0.0,
      max_tokens: 500,
      req_http_options: [receive_timeout: timeout, pool_timeout: timeout]
    ]

    case ReqLLM.generate_text(model_spec, prompt, req_opts) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response) || ""
        parse_score_from_text(text) || 0

      {:error, reason} ->
        Logger.error("[Reranker] Request error: #{inspect(reason)}")
        0
    end
  end

  defp parse_score_from_text(nil), do: nil
  defp parse_score_from_text(""), do: nil

  defp parse_score_from_text(text) when is_binary(text) do
    text = String.trim(text)

    # Try direct integer parse first
    case Integer.parse(text) do
      {num, ""} when num >= 0 and num <= 10 ->
        num

      {num, _} when num >= 0 and num <= 10 ->
        num

      _ ->
        # Try to extract a number using regex
        extract_number_from_text(text)
    end
  end

  defp extract_number_from_text(text) do
    # Look for patterns like "8", "Score: 8", "8/10", etc.
    case Regex.run(~r/\b(\d{1,2})\b/, text) do
      [_, num_str] ->
        case Integer.parse(num_str) do
          {num, _} when num >= 0 and num <= 10 -> num
          {num, _} when num > 10 -> 10
          _ -> nil
        end

      nil ->
        # Check for yes/true patterns (high relevance)
        cond do
          Regex.match?(~r/\b(yes|true|relevant|match)\b/i, text) -> 8
          Regex.match?(~r/\b(no|false|irrelevant|not)\b/i, text) -> 2
          true -> nil
        end
    end
  end
end
