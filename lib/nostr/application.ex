defmodule Nostr.Application do
	use Application

	def start(_type, _args) do
		children = [
			Nostr.Relay.RelayManager
			#{Nostr.Client, %{relay_urls: [], filters: []}}
		]

		Supervisor.start_link(children, strategy: :one_for_one)
	end
end
