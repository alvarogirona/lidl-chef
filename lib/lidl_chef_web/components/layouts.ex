defmodule LidlChefWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use LidlChefWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col bg-base-100">
      <%!-- Clean Modern Header --%>
      <header class="sticky top-0 z-50 bg-base-100/80 backdrop-blur-lg border-b border-base-200">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div class="flex items-center justify-between h-16">
            <%!-- Logo & Brand --%>
            <a href="/" class="flex items-center gap-3 group">
              <div class="w-9 h-9 bg-[#0050AA] rounded-lg flex items-center justify-center group-hover:scale-105 transition-transform">
                <span class="text-white text-lg">🍳</span>
              </div>
              <span class="font-bold text-xl text-base-content">Lidl Chef</span>
            </a>

            <%!-- Navigation --%>
            <nav class="hidden md:flex items-center gap-1">
              <.link
                navigate="/"
                class="px-4 py-2 text-base-content/70 hover:text-base-content hover:bg-base-200 rounded-lg transition-all text-sm font-medium"
              >
                Home
              </.link>
              <.link
                navigate="/products"
                class="px-4 py-2 text-base-content/70 hover:text-base-content hover:bg-base-200 rounded-lg transition-all text-sm font-medium"
              >
                Products
              </.link>
              <.link
                navigate="/recipes"
                class="px-4 py-2 text-base-content/70 hover:text-base-content hover:bg-base-200 rounded-lg transition-all text-sm font-medium"
              >
                Recipes
              </.link>
              <.link
                navigate="/chat"
                class="px-4 py-2 text-base-content/70 hover:text-base-content hover:bg-base-200 rounded-lg transition-all text-sm font-medium"
              >
                AI Chat
              </.link>
              <.link
                navigate="/arcana"
                class="px-4 py-2 text-base-content/70 hover:text-base-content hover:bg-base-200 rounded-lg transition-all text-sm font-medium"
              >
                Dashboard
              </.link>
            </nav>

            <%!-- Right side actions --%>
            <div class="flex items-center gap-3">
              <.theme_toggle />
              <.link
                navigate="/chat"
                class="hidden sm:flex items-center gap-2 bg-[#0050AA] hover:bg-[#003d80] text-white font-medium px-4 py-2 rounded-lg transition-all text-sm"
              >
                Start Cooking
              </.link>
            </div>
          </div>
        </div>
      </header>

      <%!-- Main Content - flex-1 allows it to grow --%>
      <main class="flex-1 flex flex-col">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="flex items-center bg-base-200 rounded-full p-1">
      <button
        class="p-1.5 rounded-full transition-colors [[data-theme=light]_&]:bg-base-100 [[data-theme=light]_&]:shadow-sm"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Light mode"
      >
        <.icon name="hero-sun-micro" class="w-4 h-4 text-base-content/70" />
      </button>
      <button
        class="p-1.5 rounded-full transition-colors [[data-theme=dark]_&]:bg-base-100 [[data-theme=dark]_&]:shadow-sm"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Dark mode"
      >
        <.icon name="hero-moon-micro" class="w-4 h-4 text-base-content/70" />
      </button>
    </div>
    """
  end
end
