defmodule LidlChef.Reranker do
  @moduledoc """
  Custom reranker using the smaller qwen3-reranker-0.6b model.

  This reranker uses a lightweight model specifically optimized for reranking tasks,
  with a custom prompt designed for recipe ranking based on ingredients and user preferences.
  """

  @behaviour Arcana.Agent.Reranker
  require Logger

  @model "qwen3-reranker-0.6b"
  @base_url "http://127.0.0.1:1234"
  @default_threshold 5
  @default_timeout 60_000

  @recipe_prompt_template """
  You are a recipe relevance scorer. Rate how well the recipe matches the user's request.

  User request: {question}

  Recipe:
  {chunk_text}

  Scoring criteria (0-10):
  - 10: Recipe uses the exact ingredients mentioned and fits the request perfectly
  - 7-9: Recipe uses most of the mentioned ingredients or closely matches preferences
  - 4-6: Recipe uses some mentioned ingredients or partially matches the request
  - 1-3: Recipe has minimal relevance to the request
  - 0: Recipe is completely unrelated

  IMPORTANT: A recipe does NOT need to use ALL mentioned ingredients. If it uses SOME of them well, it deserves a good score.

  Return only a single number from 0 to 10.
  """

  @impl Arcana.Agent.Reranker
  def rerank(_question, [], _opts), do: {:ok, []}

  def rerank(question, chunks, opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    Logger.info("[Reranker] Received #{length(chunks)} chunks to rerank")

    scored_chunks =
      chunks
      |> Enum.map(fn chunk ->
        prompt = build_prompt(question, chunk.text)
        Logger.info("[Reranker] Generated prompt:\n#{prompt}")

        score = get_score(prompt)
        {chunk, score}
      end)
      |> Enum.filter(fn {_chunk, score} -> score >= threshold end)
      |> Enum.sort_by(fn {_chunk, score} -> score end, :desc)
      |> Enum.map(fn {chunk, _score} -> chunk end)

    {:ok, scored_chunks}
  end

  defp build_prompt(question, chunk_text) do
    @recipe_prompt_template
    |> String.replace("{question}", question)
    |> String.replace("{chunk_text}", chunk_text)
  end

  defp get_score(prompt) do
    body = %{
      model: @model,
      messages: [
        %{role: "user", content: prompt}
      ],
      temperature: 0.1,
      max_tokens: 50
    }

    case Req.post("#{@base_url}/v1/chat/completions",
           json: body,
           receive_timeout: @default_timeout,
           pool_timeout: @default_timeout,
           connect_options: [timeout: @default_timeout]
         ) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        Logger.info("[Reranker] LLM response: #{inspect(response_body)}")
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

    Logger.info("[Reranker] Content: #{content}, Reasoning: #{reasoning_content}")

    # Parse the score from content - it should be a number 0-10
    case parse_score_from_content(content) do
      {:ok, score} -> score
      :error -> 0
    end
  end

  defp parse_score_from_content(content) when is_binary(content) do
    content
    |> String.trim()
    |> extract_number()
  end

  defp parse_score_from_content(_), do: :error

  defp extract_number(text) do
    # Try to extract a number from the text (handles "7", "7/10", "Score: 7", etc.)
    case Regex.run(~r/\b(\d+)\b/, text) do
      [_, num_str] ->
        case Integer.parse(num_str) do
          {num, _} when num >= 0 and num <= 10 -> {:ok, num}
          {num, _} when num > 10 -> {:ok, 10}
          _ -> :error
        end

      nil ->
        :error
    end
  end
end
