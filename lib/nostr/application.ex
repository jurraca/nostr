defmodule Nostr.Application do
  use Application

  def start(_type, _args) do
    children = [
      Nostr.Relay.RelayManager,
      {Registry,
       [
         keys: :duplicate,
         name: Registry.PubSub,
         partitions: System.schedulers_online()
       ]}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one)

    if Application.get_env(:nostr, :connect_on_startup) do
      connect_relays()
      result
    else
      result
    end
  end

  defp connect_relays() do
    relays = Application.get_env(:nostr, :relays)
    Nostr.Client.load_configuration(%{relays: relays, filters: []})
  end
end
