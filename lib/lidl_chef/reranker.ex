defmodule LidlChef.Reranker do
  @moduledoc """
  Custom reranker using the smaller qwen3-reranker-0.6b model.

  This reranker uses a lightweight model specifically optimized for reranking tasks,
  with a custom prompt designed for recipe ranking based on ingredients and user preferences.

  ## Options

  - `:threshold` - Minimum score for a chunk to be included (default: 5)
  - `:concurrency` - Max parallel requests to LLM server (default: 10)
  - `:base_url` - Base URL for the LLM server (default: "http://127.0.0.1:8080")
  """

  @behaviour Arcana.Agent.Reranker
  require Logger

  @model "qwen3-reranker-0.6b"
  @base_url "http://127.0.0.1:8080"
  @default_threshold 5
  @default_timeout :infinity

  # Req configuration for HTTP requests
  # Req automatically handles connection pooling internally
  defp req_client(base_url \\ @base_url) do
    Req.new(
      base_url: base_url,
      receive_timeout: @default_timeout,
      retry: false
    )
  end

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
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    concurrency = Keyword.get(opts, :concurrency, 10)
    base_url = Keyword.get(opts, :base_url, @base_url)

    Logger.info("[Reranker] Received #{length(chunks)} chunks to rerank (concurrency: #{concurrency}, base_url: #{base_url})")

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
        timeout: @default_timeout,
        ordered: false
      )
      |> Enum.reduce([], fn
        {:ok, result}, acc -> [result | acc]
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

  defp get_score(prompt, base_url \\ @base_url) do
    body = %{
      model: @model,
      messages: [
        %{role: "user", content: prompt}
      ],
      temperature: 0.0,
      max_tokens: 500
    }

    case Req.post(req_client(base_url), url: "/v1/chat/completions", json: body) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        parse_reranker_response(response_body)

      {:ok, %Req.Response{status: status, body: error_body}} ->
        Logger.error("[Reranker] HTTP error #{status}: #{inspect(error_body)}")
        0

      {:error, reason} ->
        Logger.error("[Reranker] Request error: #{inspect(reason)}")
        0
    end
  end

  defp parse_reranker_response(response_body) do
    # qwen3-reranker outputs score in "content" field and reasoning in "reasoning_content"
    choice =
      response_body
      |> Map.get("choices", [])
      |> List.first()
      |> Map.get("message", %{})

    content = Map.get(choice, "content", "")
    reasoning_content = Map.get(choice, "reasoning_content", "")

    Logger.info("[Reranker] Content: #{inspect(content)}, Reasoning: #{inspect(reasoning_content)}")

    # Try to extract score from content first, then from reasoning
    score = parse_score_from_text(content) || parse_score_from_text(reasoning_content) || 0

    Logger.info("[Reranker] Parsed score: #{score}")
    score
  end

  defp parse_score_from_text(nil), do: nil
  defp parse_score_from_text(""), do: nil

  defp parse_score_from_text(text) when is_binary(text) do
    text = String.trim(text)

    # Try direct integer parse first
    case Integer.parse(text) do
      {num, ""} when num >= 0 and num <= 10 -> num
      {num, _} when num >= 0 and num <= 10 -> num
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
