defmodule Nostr.RelaySocket do
  require Logger

  alias Nostr.RelaySocket.Server

  defstruct [
    :conn,
    :websocket,
    :request_ref,
    :caller,
    :status,
    :resp_headers,
    :closing?,
    subscriptions: []
  ]

  @doc """
  Creates a socket to a relay

  ## Examples
    iex> Nostr.RelaySocket.start_link("wss://relay.nostr.pro")
  """
  @spec start_link(String.t()) :: {:ok, pid()} | {:error, binary()}
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

  def unsubscribe(pid, subscription_id) do
    GenServer.cast(pid, {:unsubscribe, subscription_id})
  end

  def send_event(pid, event) do
    GenServer.cast(pid, {:send_event, event})
  end

  def subscribe_profile(pid, pubkey) do
    GenServer.call(pid, {:profile, pubkey, self()})
  end

  def subscribe_contacts(pid, pubkey, limit \\ 10) do
    GenServer.call(pid, {:contacts, pubkey, limit, self()})
  end

  def subscribe_notes(pid, pubkeys, limit \\ 10) when is_list(pubkeys) do
    GenServer.call(pid, {:notes, pubkeys, limit, self()})
  end
end
