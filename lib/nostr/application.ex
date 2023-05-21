defmodule Nostr.Application do
	use Application

	def start(_type, _args) do
		children = [
			Nostr.Relay.RelayManager,
			{Nostr.Client, default_config()}
		]

		Supervisor.start_link(children, strategy: :one_for_one)
	end

	def default_config() do
		%{
		    relay_urls: [ "ws://localhost:8080" ],
		    filters: []
		}
	end
end