defmodule Nostr.Relay.Socket do
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

  def subscribe_profile(caller, relay_pid, pubkey) do
    GenServer.call(relay_pid, {:profile, pubkey, caller})
  end

  def subscribe_recommended_servers(caller, relay_pid) do
    GenServer.call(relay_pid, {:recommended_servers, caller})
  end

  @spec subscribe_contacts(pid(), pid(), <<_::256>>) :: atom()
  def subscribe_contacts(caller, relay_pid, pubkey, limit \\ 10) do
    GenServer.call(relay_pid, {:contacts, pubkey, limit, caller})
  end

  @spec subscribe_note(pid(), pid(), <<_::256>>) :: atom()
  def subscribe_note(caller, relay_pid, note_id) do
    GenServer.call(relay_pid, {:note, note_id, caller})
  end

  @spec subscribe_kinds(pid(), pid(), list(integer()), integer()) :: atom()
  def subscribe_kinds(caller, relay_pid, kinds, limit \\ 10) when is_list(kinds) do
    GenServer.call(relay_pid, {:kinds, kinds, limit, caller})
  end

  @spec subscribe_notes(pid(), pid(), list(<<_::256>>), integer()) :: atom()
  def subscribe_notes(caller, relay_pid, pubkeys, limit \\ 10) when is_list(pubkeys) do
    GenServer.call(relay_pid, {:notes, pubkeys, limit, caller})
  end

  @spec subscribe_deletions(pid(), pid(), list(<<_::256>>), integer()) :: atom()
  def subscribe_deletions(caller, relay_pid, pubkeys, limit \\ 10) when is_list(pubkeys) do
    GenServer.call(relay_pid, {:deletions, pubkeys, limit, caller})
  end

  @spec subscribe_reposts(pid(), list(<<_::256>>), integer()) :: atom()
  def subscribe_reposts(pid, pubkeys, limit \\ 10) when is_list(pubkeys) do
    GenServer.call(pid, {:reposts, pubkeys, limit, self()})
  end

  @spec subscribe_reactions(pid(), list(<<_::256>>), integer()) :: atom()
  def subscribe_reactions(pid, pubkeys, limit \\ 10) when is_list(pubkeys) do
    GenServer.call(pid, {:reactions, pubkeys, limit, self()})
  end

  @spec subscribe_encrypted_direct_messages(pid(), <<_::256>>, integer()) ::
          atom()
  def subscribe_encrypted_direct_messages(pid, pubkey, limit \\ 10) do
    GenServer.call(pid, {:encrypted_direct_messages, pubkey, limit, self()})
  end
end
