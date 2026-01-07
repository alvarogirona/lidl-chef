defmodule LidlChef.Repo do
  use Ecto.Repo,
    otp_app: :lidl_chef,
    adapter: Ecto.Adapters.Postgres
end
