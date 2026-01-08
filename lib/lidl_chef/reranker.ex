defmodule LidlChef.Reranker do
  @moduledoc """
  Custom reranker using the smaller qwen3-reranker-0.6b model.

  This reranker uses a lightweight model specifically optimized for reranking tasks,
  with a custom prompt designed for recipe ranking that understands recipes just need
  to include some of the mentioned ingredients to be relevant.
  """

  @behaviour Arcana.Agent.Reranker
  require Logger

  @default_threshold 3

  @recipe_prompt_template """
  Question: Does this recipe answer "Que puedo cocinar con {question_keyword}"?

  Recipe title and ingredients:
  {chunk_text}

  Score 0-10 (7-10=yes it has the ingredient, 0-6=no or unrelated):
  """

  @impl Arcana.Agent.Reranker
  def rerank(_question, [], _opts), do: {:ok, []}

  def rerank(question, chunks, opts) do
    # Use the smaller reranker model via a custom LLM function
    # that maps qwen3-reranker-0.6b response to Arcana's expected format
    reranker_llm = fn prompt ->
      Logger.debug("[Reranker] Sending prompt to qwen3-reranker-0.6b")
      Logger.debug("[Reranker] Prompt (first 300 chars): #{String.slice(prompt, 0, 300)}")

      case LidlChef.LLM.complete(prompt,
             model: "qwen3-reranker-0.6b",
             temperature: 0.1,
             max_tokens: 50
           ) do
        {:ok, response} ->
          Logger.debug("[Reranker] Response from model: #{inspect(response)}")

          # qwen3-reranker returns just the score (e.g., "0", "10")
          # Map it to Arcana's expected JSON format
          score =
            case Integer.parse(String.trim(response)) do
              {num, _} ->
                Logger.debug("[Reranker] Parsed score: #{num}")
                num
              _ ->
                Logger.debug("[Reranker] Failed to parse response as integer, defaulting to 0")
                0
            end

          # Return JSON format Arcana expects
          json_response = "{\"score\": #{score}, \"reasoning\": \"Recipe relevance score: #{score}\"}"
          Logger.debug("[Reranker] Returning: #{json_response}")
          {:ok, json_response}

        {:error, err} ->
          Logger.error("[Reranker] LLM error: #{inspect(err)}")
          err
      end
    end

    # Custom prompt function for recipe ranking
    prompt_fn = fn question, chunk_text ->
      # Extract main keyword from question (first noun-like word)
      keyword = question |> String.split() |> Enum.find("receta", &(String.length(&1) > 2))

      prompt = @recipe_prompt_template
      |> String.replace("{question}", question)
      |> String.replace("{question_keyword}", keyword)
      Logger.debug("[Reranker] Full prompt for chunk:\n#{prompt}")
      prompt
    end

    # Configure threshold
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    Logger.debug("[Reranker] Starting rerank with threshold: #{threshold}, chunks: #{length(chunks)}")

    # Use Arcana's LLM reranker with our custom LLM function and prompt
    result = Arcana.Agent.Reranker.LLM.rerank(question, chunks,
      llm: reranker_llm,
      threshold: threshold,
      prompt: prompt_fn
    )

    case result do
      {:ok, reranked} ->
        Logger.debug("[Reranker] Rerank complete: #{length(reranked)} of #{length(chunks)} chunks passed threshold")
        {:ok, reranked}
      err ->
        Logger.error("[Reranker] Rerank error: #{inspect(err)}")
        err
    end
  end
end
