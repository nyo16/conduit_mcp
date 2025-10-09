defmodule PhoenixMcpWeb.PageController do
  use PhoenixMcpWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
