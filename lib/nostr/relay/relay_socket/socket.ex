defmodule Nostr.Relay.Socket do
  @moduledoc """
  The public facing API to our relay GenServer.
  Initiates connections to relays via websocket and handles event sending and subscription.
  """
  require Logger

  alias Nostr.Relay.Socket.Server

  defstruct [
    :url,
    :conn,
    :websocket,
    :request_ref,
    :owner_pid,
    :caller,
    :status,
    :resp_headers,
    :closing?,
    subscriptions: []
  ]

  @doc """
  Creates a socket to a relay

  ## Examples
    iex> Nostr.Relay.RelaySocket.start_link("wss://relay.nostr.pro")
  """
  @spec start_link(list()) :: GenServer.on_start()
  def start_link([relay_url, owner_pid]) do
    GenServer.start_link(Server, %{relay_url: relay_url, owner_pid: owner_pid})
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def subscriptions(pid) do
    GenServer.call(pid, {:subscriptions})
  end

  def ready?(pid) do
    GenServer.call(pid, :ready?)
  end

  def url(pid) do
    GenServer.call(pid, :url)
  end

  def subscribe(relay_pid, sub_id, encoded_filter) do
    case ready?(relay_pid) do
      true -> GenServer.cast(relay_pid, {:subscribe, sub_id, encoded_filter})
      false ->
        :timer.sleep(100)
        subscribe(relay_pid, sub_id, encoded_filter)
    end
  end

  @doc """
  Revokes a subscription from a relay
  """
  @spec unsubscribe(pid(), atom()) :: :ok
  def unsubscribe(pid, subscription_id) do
    GenServer.cast(pid, {:unsubscribe, subscription_id})
  end

  def send_event(pid, event) do
    GenServer.cast(pid, {:send_event, event})
  end

  #@spec subscribe_all(pid(), pid(), integer()) :: atom()
  def subscribe_all(caller, relay_pid, limit \\ 10) do
    GenServer.call(relay_pid, {:all, limit, caller})
  end
end
