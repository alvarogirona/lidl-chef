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

  defp format_error({:no_answer, _}),
    do: "No encontré recetas relevantes para tu consulta. Intenta reformular tu pregunta."

  defp format_error({:agent_error, msg}), do: "Ha ocurrido un error: #{msg}"
  defp format_error(reason), do: "Algo salió mal: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div class="flex-1 flex flex-col max-w-4xl mx-auto w-full px-4 sm:px-6 py-6">
        <%!-- Header --%>
        <div class="text-center mb-6 flex-shrink-0">
          <h1 class="text-2xl font-bold text-base-content mb-1">Asistente de Recetas IA</h1>
          <p class="text-base-content/60 text-sm">¡Pregúntame lo que quieras sobre recetas!</p>
        </div>

        <%!-- Suggestions for empty state --%>
        <div :if={@messages == []} class="flex-1 flex items-center justify-center">
          <div class="text-center max-w-2xl w-full">
            <div class="w-16 h-16 bg-[#0050AA]/10 rounded-2xl flex items-center justify-center mx-auto mb-6">
              <span class="text-3xl">🍳</span>
            </div>
            <h2 class="text-lg font-semibold text-base-content mb-2">
              ¿Qué te gustaría cocinar hoy?
            </h2>
            <p class="text-base-content/60 text-sm mb-6">Prueba una de estas sugerencias:</p>
            <div class="grid gap-2">
              <button
                phx-click="send_suggestion"
                phx-value-message="Tengo tomate, pasta y carne. ¿Qué puedo preparar?"
                class="p-3 bg-base-200 border border-base-300 rounded-xl hover:border-[#0050AA]/50 hover:bg-base-100 transition-all text-left text-sm"
              >
                <span class="text-base-content/80">
                  "Tengo tomate, pasta y carne. ¿Qué puedo preparar?"
                </span>
              </button>
              <button
                phx-click="send_suggestion"
                phx-value-message="Me gustaría preparar una receta vegana, ¿qué me sugieres?"
                class="p-3 bg-base-200 border border-base-300 rounded-xl hover:border-[#0050AA]/50 hover:bg-base-100 transition-all text-left text-sm"
              >
                <span class="text-base-content/80">
                  "Me gustaría preparar una receta vegana, ¿qué me sugieres?"
                </span>
              </button>
              <button
                phx-click="send_suggestion"
                phx-value-message="Quiero que me sugieras un menú diario (desayuno, comida y cena) vegano. ¿Qué recetas me recomiendas?"
                class="p-3 bg-base-200 border border-base-300 rounded-xl hover:border-[#FFF000]/50 hover:bg-base-100 transition-all text-left text-sm"
              >
                <span class="text-base-content/80">"Quiero que me sugieras un menú diario vegano"</span>
              </button>
              <button
                phx-click="send_suggestion"
                phx-value-message="Puedes darme un menú semanal variado alto en proteínas?"
                class="p-3 bg-base-200 border border-base-300 rounded-xl hover:border-[#FFF000]/50 hover:bg-base-100 transition-all text-left text-sm"
              >
                <span class="text-base-content/80">
                  "Puedes darme un menú semanal variado alto en proteínas?"
                </span>
              </button>
              <button
                phx-click="send_suggestion"
                phx-value-message="Tengo tofu y naranja, quiero preparar una comida vegana"
                class="p-3 bg-base-200 border border-base-300 rounded-xl hover:border-[#0050AA]/50 hover:bg-base-100 transition-all text-left text-sm"
              >
                <span class="text-base-content/80">
                  "Tengo tofu y naranja, quiero preparar una comida vegana"
                </span>
              </button>
            </div>
          </div>
        </div>

        <%!-- Chat Messages --%>
        <div
          :if={@messages != []}
          class="flex-1 overflow-y-auto space-y-4 mb-4"
          id="chat-messages"
          phx-hook="ScrollToBottom"
        >
          <div
            :for={message <- @messages}
            class={[
              "flex",
              message.role == :user && "justify-end",
              message.role == :assistant && "justify-start"
            ]}
          >
            <div class={[
              "max-w-[85%] rounded-2xl px-4 py-3",
              message.role == :user && "bg-[#0050AA] text-white",
              message.role == :assistant && "bg-base-200 text-base-content"
            ]}>
              <div :if={message.role == :assistant} class="prose prose-sm max-w-none dark:prose-invert">
                {raw(format_markdown(message.content))}
              </div>
              <div :if={message.role == :user}>
                {message.content}
              </div>
            </div>
          </div>

          <%!-- Loading indicator --%>
          <div :if={@loading} class="flex justify-start">
            <div class="bg-base-200 rounded-2xl px-4 py-3">
              <div class="flex items-center gap-2 text-base-content/60">
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
        <div :if={@error} class="mb-4 p-3 bg-[#E60A14]/10 border border-[#E60A14]/20 rounded-xl text-[#E60A14] text-sm flex-shrink-0">
          {@error}
        </div>

        <%!-- Input Form --%>
        <div class="flex-shrink-0 bg-base-100 border border-base-300 rounded-2xl p-2">
          <.form
            for={%{}}
            phx-submit="send_message"
            phx-change="update_input"
            id="chat-form"
            class="flex gap-2"
          >
            <input
              type="text"
              name="chat[message]"
              value={@input}
              placeholder="Ask about recipes, ingredients, or cooking ideas..."
              class="flex-1 px-4 py-3 bg-transparent border-0 focus:ring-0 focus:outline-none text-base-content placeholder-base-content/40 text-sm"
              disabled={@loading}
              autocomplete="off"
            />
            <button
              type="submit"
              disabled={@loading || String.trim(@input) == ""}
              class={[
                "px-5 py-2.5 rounded-xl font-medium transition-all text-sm",
                "bg-[#0050AA] text-white hover:bg-[#003d80]",
                "disabled:bg-base-300 disabled:text-base-content/40 disabled:cursor-not-allowed"
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
    |> String.replace(
      ~r/\[([^\]]+)\]\(([^)]+)\)/,
      "<a href=\"\\2\" target=\"_blank\" class=\"text-blue-600 hover:underline\">\\1</a>"
    )
    |> String.replace(~r/^### (.+)$/m, "<h3 class=\"font-bold text-lg mt-4 mb-2\">\\1</h3>")
    |> String.replace(~r/^## (.+)$/m, "<h2 class=\"font-bold text-xl mt-4 mb-2\">\\1</h2>")
    |> String.replace(~r/^# (.+)$/m, "<h1 class=\"font-bold text-2xl mt-4 mb-2\">\\1</h1>")
    |> String.replace(~r/^- (.+)$/m, "<li class=\"ml-4\">\\1</li>")
    |> String.replace(~r/(<li.*<\/li>)+/s, "<ul class=\"list-disc my-2\">\\0</ul>")
    |> String.replace(~r/\n\n/, "</p><p class=\"my-2\">")
    |> then(&"<p class=\"my-2\">#{&1}</p>")
    # Only convert plain URLs that are NOT already inside HTML tags (negative lookbehind)
    |> String.replace(
      ~r/(?<!href=")(?<!">)(https?:\/\/[^\s<)"]+)(?![^<]*<\/a>)/,
      "<a href=\"\\1\" target=\"_blank\" class=\"text-blue-600 hover:underline\">\\1</a>"
    )
  end
end
