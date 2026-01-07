defmodule LidlChefWeb.ChefChatLive do
  use LidlChefWeb, :live_view

  alias LidlChef.RecipeAssistant

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:messages, [])
     |> assign(:input, "")
     |> assign(:loading, false)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("send_message", %{"chat" => %{"message" => message}}, socket) do
    message = String.trim(message)

    if message != "" do
      # Add user message to chat
      user_message = %{role: :user, content: message, timestamp: DateTime.utc_now()}

      # Send async task to process with LLM
      send(self(), {:process_message, message})

      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [user_message])
       |> assign(:input, "")
       |> assign(:loading, true)
       |> assign(:error, nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_input", %{"chat" => %{"message" => value}}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  @impl true
  def handle_event("send_suggestion", %{"message" => message}, socket) do
    # Add user message to chat
    user_message = %{role: :user, content: message, timestamp: DateTime.utc_now()}

    # Send async task to process with LLM
    send(self(), {:process_message, message})

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [user_message])
     |> assign(:input, "")
     |> assign(:loading, true)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_info({:process_message, message}, socket) do
    case RecipeAssistant.ask(message, limit: 5, self_correct: false) do
      {:ok, response} ->
        assistant_message = %{role: :assistant, content: response, timestamp: DateTime.utc_now()}

        {:noreply,
         socket
         |> assign(:messages, socket.assigns.messages ++ [assistant_message])
         |> assign(:loading, false)}

      {:error, reason} ->
        error_message = format_error(reason)

        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error, error_message)}
    end
  end

  defp format_error({:no_answer, _}), do: "I couldn't find relevant recipes for your query. Try rephrasing your question."
  defp format_error({:agent_error, msg}), do: "An error occurred: #{msg}"
  defp format_error(reason), do: "Something went wrong: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="max-w-4xl mx-auto p-6 h-[calc(100vh-8rem)] flex flex-col">
        <%!-- Header --%>
        <div class="text-center mb-6">
          <h1 class="text-3xl font-bold text-gray-900 mb-2">👨‍🍳 Lidl Chef Chat</h1>
          <p class="text-gray-600">Ask me anything about recipes!</p>
          <div class="flex justify-center gap-4 mt-3">
            <.link navigate="/recipes" class="text-sm text-blue-600 hover:text-blue-800 underline">
              ← Back to Recipe Search
            </.link>
          </div>
        </div>

        <%!-- Suggestions for empty state --%>
        <div :if={@messages == []} class="flex-1 flex items-center justify-center">
          <div class="text-center max-w-2xl">
            <div class="text-6xl mb-6">🍳</div>
            <h2 class="text-xl font-semibold text-gray-700 mb-4">What would you like to cook today?</h2>
            <p class="text-gray-500 mb-6">Try asking me something like:</p>
            <div class="grid gap-3">
              <button
                phx-click="send_suggestion"
                phx-value-message="I have tomato, pasta and meat. What can I prepare?"
                class="p-4 bg-white border border-gray-200 rounded-lg hover:border-blue-400 hover:bg-blue-50 transition-colors text-left"
              >
                <span class="text-gray-700">"I have tomato, pasta and meat. What can I prepare?"</span>
              </button>
              <button
                phx-click="send_suggestion"
                phx-value-message="I would like to prepare a vegan recipe, what can you suggest me?"
                class="p-4 bg-white border border-gray-200 rounded-lg hover:border-blue-400 hover:bg-blue-50 transition-colors text-left"
              >
                <span class="text-gray-700">"I would like to prepare a vegan recipe, what can you suggest me?"</span>
              </button>
              <button
                phx-click="send_suggestion"
                phx-value-message="Quiero que me sugieras un menú diario (desayuno, comida y cena) vegano. ¿Qué recetas me recomiendas?"
                class="p-4 bg-white border border-gray-200 rounded-lg hover:border-green-400 hover:bg-green-50 transition-colors text-left"
              >
                <span class="text-gray-700">"Quiero que me sugieras un menú diario vegano"</span>
              </button>
              <button
                phx-click="send_suggestion"
                phx-value-message="Puedes darme un menú semanal variado alto en proteínas?"
                class="p-4 bg-white border border-gray-200 rounded-lg hover:border-green-400 hover:bg-green-50 transition-colors text-left"
              >
                <span class="text-gray-700">"Puedes darme un menú semanal variado alto en proteínas?"</span>
              </button>
              <button
                phx-click="send_suggestion"
                phx-value-message="Tengo tofu y naranja, quiero preparar una comida vegana"
                class="p-4 bg-white border border-gray-200 rounded-lg hover:border-blue-400 hover:bg-blue-50 transition-colors text-left"
              >
                <span class="text-gray-700">"Tengo tofu y naranja, quiero preparar una comida vegana"</span>
              </button>
            </div>
          </div>
        </div>

        <%!-- Chat Messages --%>
        <div :if={@messages != []} class="flex-1 overflow-y-auto mb-4 space-y-4" id="chat-messages" phx-hook="ScrollToBottom">
          <div :for={message <- @messages} class={[
            "flex",
            message.role == :user && "justify-end",
            message.role == :assistant && "justify-start"
          ]}>
            <div class={[
              "max-w-[80%] rounded-2xl px-4 py-3 shadow-sm",
              message.role == :user && "bg-blue-600 text-white",
              message.role == :assistant && "bg-white border border-gray-200 text-gray-800"
            ]}>
              <div :if={message.role == :assistant} class="prose prose-sm max-w-none">
                {raw(format_markdown(message.content))}
              </div>
              <div :if={message.role == :user}>
                {message.content}
              </div>
            </div>
          </div>

          <%!-- Loading indicator --%>
          <div :if={@loading} class="flex justify-start">
            <div class="bg-white border border-gray-200 rounded-2xl px-4 py-3 shadow-sm">
              <div class="flex items-center gap-2 text-gray-500">
                <div class="flex gap-1">
                  <span class="animate-bounce delay-0">●</span>
                  <span class="animate-bounce delay-100">●</span>
                  <span class="animate-bounce delay-200">●</span>
                </div>
                <span class="text-sm">Thinking...</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Error message --%>
        <div :if={@error} class="mb-4 p-4 bg-red-50 border border-red-200 rounded-lg text-red-700">
          {@error}
        </div>

        <%!-- Input Form --%>
        <div class="bg-white border border-gray-200 rounded-2xl p-2 shadow-lg">
          <.form for={%{}} phx-submit="send_message" phx-change="update_input" id="chat-form" class="flex gap-2">
            <input
              type="text"
              name="chat[message]"
              value={@input}
              placeholder="Ask about recipes, ingredients, or cooking ideas..."
              class="flex-1 px-4 py-3 border-0 focus:ring-0 text-gray-800 placeholder-gray-400"
              disabled={@loading}
              autocomplete="off"
            />
            <button
              type="submit"
              disabled={@loading || String.trim(@input) == ""}
              class={[
                "px-6 py-3 rounded-xl font-medium transition-all",
                "bg-blue-600 text-white hover:bg-blue-700",
                "disabled:bg-gray-300 disabled:cursor-not-allowed"
              ]}
            >
              <span :if={!@loading}>Send</span>
              <span :if={@loading}>...</span>
            </button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Simple markdown to HTML conversion for chat messages
  defp format_markdown(text) do
    text
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/\*(.+?)\*/, "<em>\\1</em>")
    |> String.replace(~r/\[([^\]]+)\]\(([^)]+)\)/, "<a href=\"\\2\" target=\"_blank\" class=\"text-blue-600 hover:underline\">\\1</a>")
    |> String.replace(~r/^### (.+)$/m, "<h3 class=\"font-bold text-lg mt-4 mb-2\">\\1</h3>")
    |> String.replace(~r/^## (.+)$/m, "<h2 class=\"font-bold text-xl mt-4 mb-2\">\\1</h2>")
    |> String.replace(~r/^# (.+)$/m, "<h1 class=\"font-bold text-2xl mt-4 mb-2\">\\1</h1>")
    |> String.replace(~r/^- (.+)$/m, "<li class=\"ml-4\">\\1</li>")
    |> String.replace(~r/(<li.*<\/li>)+/s, "<ul class=\"list-disc my-2\">\\0</ul>")
    |> String.replace(~r/\n\n/, "</p><p class=\"my-2\">")
    |> then(&"<p class=\"my-2\">#{&1}</p>")
    # Only convert plain URLs that are NOT already inside HTML tags (negative lookbehind)
    |> String.replace(~r/(?<!href=")(?<!">)(https?:\/\/[^\s<)"]+)(?![^<]*<\/a>)/, "<a href=\"\\1\" target=\"_blank\" class=\"text-blue-600 hover:underline\">\\1</a>")
  end
end
