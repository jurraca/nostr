defmodule Nostr.Application do
	use Application

	def start(_type, _args) do
		children = [
			Nostr.Relay.RelayManager,
			{Registry, [
				keys: :duplicate,
				name: Registry.PubSub,
				partitions: System.schedulers_online()
			]}
		]

		Supervisor.start_link(children, strategy: :one_for_one)
	end
end
