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
      assistant_message = %{role: :assistant, content: "", timestamp: DateTime.utc_now()}

      # Send async task to process with streaming LLM
      send(self(), {:process_message_stream, message})

      {:noreply,
       socket
       |> assign(:messages, socket.assigns.messages ++ [user_message, assistant_message])
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
    assistant_message = %{role: :assistant, content: "", timestamp: DateTime.utc_now()}

    # Send async task to process with streaming LLM
    send(self(), {:process_message_stream, message})

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [user_message, assistant_message])
     |> assign(:input, "")
     |> assign(:loading, true)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_info({:process_message_stream, message}, socket) do
    parent = self()

    Task.start(fn ->
      result =
        RecipeAssistant.ask_stream(
          message,
          fn chunk -> send(parent, {:assistant_chunk, chunk}) end,
          limit: 5,
          self_correct: false
        )

      send(parent, {:assistant_done, result})
    end)

    {:noreply, socket}
  end

  def handle_info({:assistant_chunk, chunk}, socket) do
    {:noreply, update(socket, :messages, &append_to_last_assistant(&1, chunk))}
  end

  def handle_info({:assistant_done, {:ok, full_text}}, socket) do
    {:noreply,
     socket
     |> assign(:messages, set_last_assistant(socket.assigns.messages, full_text))
     |> assign(:loading, false)}
  end

  def handle_info({:assistant_done, {:error, reason}}, socket) do
    error_message = format_error(reason)

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:error, error_message)}
  end

  defp format_error({:no_answer, _}),
    do: "No encontré recetas relevantes para tu consulta. Intenta reformular tu pregunta."

  defp format_error({:agent_error, msg}), do: "Ha ocurrido un error: #{msg}"
  defp format_error(reason), do: "Algo salió mal: #{inspect(reason)}"

  defp append_to_last_assistant(messages, chunk) do
    case Enum.reverse(messages) do
      [%{role: :assistant} = last | rest] ->
        new_content =
          cond do
            last.content == "" ->
              chunk
            String.starts_with?(chunk, last.content) ->
              chunk
            true ->
              last.content <> chunk
          end

        updated_last = %{last | content: new_content}
        Enum.reverse([updated_last | rest])

      _ ->
        messages
    end
  end

  defp set_last_assistant(messages, content) do
    case Enum.reverse(messages) do
      [%{role: :assistant} = last | rest] ->
        updated_last = %{last | content: content}
        Enum.reverse([updated_last | rest])

      _ ->
        messages
    end
  end

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
                <span class="text-base-content/80">
                  "Quiero que me sugieras un menú diario vegano"
                </span>
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
              "max-w-[90%] rounded-2xl px-4 py-3",
              message.role == :user && "bg-[#0050AA] text-white",
              message.role == :assistant && "bg-base-200 text-base-content"
            ]}>
              <div
                :if={message.role == :assistant}
                class="prose prose-sm max-w-none dark:prose-invert [&_ul]:list-none [&_li]:pl-0"
              >
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
        <div
          :if={@error}
          class="mb-4 p-3 bg-[#E60A14]/10 border border-[#E60A14]/20 rounded-xl text-[#E60A14] text-sm flex-shrink-0"
        >
          {@error}
        </div>

        <%!-- Input Form --%>
        <div class="flex-shrink-0">
          <.form
            for={%{}}
            phx-submit="send_message"
            phx-change="update_input"
            id="chat-form"
            class="flex gap-3 p-4 bg-base-200/50 backdrop-blur-sm border border-base-300 rounded-2xl shadow-sm"
          >
            <input
              type="text"
              name="chat[message]"
              value={@input}
              placeholder="Pregúntame sobre recetas, ingredientes o ideas de cocina..."
              class="flex-1 px-4 py-3 bg-base-100 border border-base-300 rounded-xl text-base-content placeholder-base-content/50 text-sm focus:outline-none focus:ring-2 focus:ring-[#0050AA]/20 focus:border-[#0050AA] transition-all shadow-sm"
              disabled={@loading}
              autocomplete="off"
            />
            <button
              type="submit"
              disabled={@loading || String.trim(@input) == ""}
              class={[
                "px-6 py-3 rounded-xl font-medium transition-all text-sm shadow-sm",
                "bg-[#0050AA] text-white hover:bg-[#003d80] hover:shadow-lg hover:scale-105",
                "disabled:bg-base-300 disabled:text-base-content/40 disabled:cursor-not-allowed disabled:scale-100 disabled:shadow-none"
              ]}
            >
              <span :if={!@loading} class="flex items-center gap-2">
                <.icon name="hero-paper-airplane" class="w-4 h-4" /> Enviar
              </span>
              <span :if={@loading} class="flex items-center gap-2">
                <div class="w-4 h-4 border-2 border-white/30 border-t-white rounded-full animate-spin">
                </div>
                Enviando...
              </span>
            </button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Enhanced markdown to HTML conversion for chat messages with better recipe formatting
  defp format_markdown(text) do
    text
    # Format recipe titles (lines starting with "Recipe:" or numbered recipes)
    |> String.replace(
      ~r/^Recipe:\s*(.+)$/m,
      "<div class=\"bg-[#0050AA]/5 border-l-4 border-[#0050AA] p-3 my-3 rounded-r-lg\"><h3 class=\"font-bold text-lg text-[#0050AA] mb-1\">🍽️ \\1</h3></div>"
    )
    |> String.replace(
      ~r/^(\d+\.\s*.+)$/m,
      "<div class=\"bg-[#0050AA]/5 border-l-4 border-[#0050AA] p-3 my-3 rounded-r-lg\"><h3 class=\"font-bold text-lg text-[#0050AA] mb-1\">🍽️ \\1</h3></div>"
    )

    # Format ingredients sections
    |> String.replace(
      ~r/^(Ingredientes?:)$/m,
      "<h4 class=\"font-semibold text-[#FFF000] bg-[#0050AA] px-3 py-1 rounded text-sm inline-block mt-3 mb-2\">🧄 \\1</h4>"
    )
    |> String.replace(
      ~r/^(Ingredients?:)$/m,
      "<h4 class=\"font-semibold text-[#FFF000] bg-[#0050AA] px-3 py-1 rounded text-sm inline-block mt-3 mb-2\">🧄 \\1</h4>"
    )

    # Format instructions sections
    |> String.replace(
      ~r/^(Instrucciones?:)$/m,
      "<h4 class=\"font-semibold text-[#FFF000] bg-[#0050AA] px-3 py-1 rounded text-sm inline-block mt-3 mb-2\">👨‍🍳 \\1</h4>"
    )
    |> String.replace(
      ~r/^(Instructions?:)$/m,
      "<h4 class=\"font-semibold text-[#FFF000] bg-[#0050AA] px-3 py-1 rounded text-sm inline-block mt-3 mb-2\">👨‍🍳 \\1</h4>"
    )

    # Format time and servings info
    |> String.replace(
      ~r/^(Tiempo de preparación:|Prep time:|Tiempo de cocción:|Cook time:|Porciones:|Servings?:)\s*(.+)$/m,
      "<div class=\"inline-flex items-center gap-2 bg-[#FFF000]/20 text-[#0050AA] px-3 py-1 rounded-full text-sm font-medium my-1 mr-2\"><span class=\"text-xs\">⏱️</span><strong>\\1</strong> \\2</div>"
    )

    # Enhanced list formatting for ingredients and steps
    |> String.replace(
      ~r/^-\s(.+)$/m,
      "<li class=\"flex items-start gap-2 py-1\"><span class=\"text-[#0050AA] font-bold mt-0.5\">•</span><span>\\1</span></li>"
    )

    # Standard markdown formatting
    |> String.replace(
      ~r/\*\*(.+?)\*\*/,
      "<strong class=\"font-bold text-base-content\">\\1</strong>"
    )
    |> String.replace(~r/\*(.+?)\*/, "<em class=\"italic\">\\1</em>")

    # Enhanced link formatting
    |> String.replace(
      ~r/\[([^\]]+)\]\(([^)]+)\)/,
      "<a href=\"\\2\" target=\"_blank\" class=\"text-[#0050AA] hover:text-[#003d80] underline font-medium inline-flex items-center gap-1\">\\1 <span class=\"text-xs\">🔗</span></a>"
    )

    # Headers with better styling
    |> String.replace(
      ~r/^### (.+)$/m,
      "<h3 class=\"font-bold text-lg mt-4 mb-2 text-base-content border-b border-base-200 pb-1\">\\1</h3>"
    )
    |> String.replace(
      ~r/^## (.+)$/m,
      "<h2 class=\"font-bold text-xl mt-4 mb-2 text-base-content\">\\1</h2>"
    )
    |> String.replace(
      ~r/^# (.+)$/m,
      "<h1 class=\"font-bold text-2xl mt-4 mb-2 text-base-content\">\\1</h1>"
    )

    # Wrap consecutive list items in proper ul tags
    |> String.replace(~r/(<li.*?<\/li>[\s\n]*)+/s, "<ul class=\"space-y-1 my-3 ml-2\">\\0</ul>")

    # Convert plain URLs (not already in HTML)
    |> String.replace(
      ~r/(?<!href=")(?<!">)(https?:\/\/[^\s<)"]+)(?![^<]*<\/a>)/,
      "<a href=\"\\1\" target=\"_blank\" class=\"text-[#0050AA] hover:text-[#003d80] underline break-all\">\\1</a>"
    )

    # Paragraph handling - preserve line breaks and add spacing
    |> String.replace(~r/\n\n/, "</p><p class=\"my-2\">")
    |> then(&"<p class=\"my-2\">#{&1}</p>")

    # Clean up empty paragraphs and improve spacing
    |> String.replace(~r/<p class="my-2"><\/p>/, "")
    |> String.replace(~r/<p class="my-2">\s*<\/p>/, "")
  end
end
