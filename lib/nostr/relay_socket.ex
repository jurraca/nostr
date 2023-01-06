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
  def start_link(relay_url) do
    GenServer.start_link(Server, %{relay_url: relay_url})
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

  def subscribe_profile(pid, pubkey) do
    GenServer.cast(pid, {:profile, pubkey, self()})
  end

  def subscribe_contacts(pid, pubkey) do
    GenServer.cast(pid, {:contacts, pubkey, self()})
  end

  def subscribe_notes(pid, pubkey) do
    GenServer.cast(pid, {:notes, pubkey, self()})
  end
end
