defmodule LidlChefWeb.PageController do
  use LidlChefWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
