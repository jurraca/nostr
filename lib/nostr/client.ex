defmodule Nostr.Client do
  @moduledoc """
  Connects to a relay through websockets
  """

  use GenServer

  require Logger

  alias NostrBasics.{Event}
  alias NostrBasics.Keys.{PublicKey, PrivateKey}
  alias NostrBasics.Models.{Profile, Note}

  alias Nostr.Relay.{RelayManager, Socket}
  alias Nostr.Client.Tasks

  alias Nostr.Client.Subscriptions.{
    RepostsSubscription,
    ReactionsSubscription,
    TimelineSubscription,
    EncryptedDirectMessagesSubscription
  }

  alias Nostr.Client.Workflows.{
    Follow,
    Unfollow,
    DeleteEvents,
    SendReaction,
    SendRepost,
    UpdateProfile
  }

  @doc """
  Starts the client
  Starts connections to relays if supplied in the default config
  The state of this GenServer will be the config (relays, filters).
  """
  @spec start_link(tuple()) :: Supervisor.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(%{relay_urls: relays, filters: _filters} = config) do
    if Enum.count(relays) > 0 do
      Enum.map(relays, &add_relay(&1))
    end
    {:ok, config}
  end

  def add_relay(relay_url) do
    RelayManager.add(relay_url)
  end

  @impl true
  def handle_info({:event, _sub_id, %NostrBasics.Event{} = event}, state) do
    print_to_console(event)
    #IO.inspect(event, label: "client event recv")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do 
    IO.inspect(msg, label: "client info msg")
    {:noreply, state}
  end

  def subscribe_all(), do: subscribe_all(RelayManager.active_pids())

  def subscribe_all(relays) do
    Enum.map(relays, &Socket.subscribe_all(__MODULE__, &1))
  end

  @doc """
  Get an author's profile
  """
  def subscribe_profile(pubkey), do: subscribe_profile(RelayManager.active_pids(), pubkey)

  @spec subscribe_profile(PublicKey.id()) :: List.t() | {:error, String.t()}
  def subscribe_profile(relays, pubkey) do
    case PublicKey.to_binary(pubkey) do
      {:ok, binary_pubkey} -> 
        Enum.map(relays, &Socket.subscribe_profile(__MODULE__, &1, binary_pubkey))

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Get an author's recommended servers
  """
  @spec subscribe_recommended_servers() :: List.t()
  def subscribe_recommended_servers() do
    RelayManager.active_pids()
    |> Enum.map(&Socket.subscribe_recommended_servers(__MODULE__, &1))
  end

  @doc """
  Update the profile that's linked to the private key
  """
  @spec update_profile(Profile.t(), PrivateKey.id()) :: GenServer.on_start()
  def update_profile(%Profile{} = profile, privkey) do
    RelayManager.active_pids()
    |> UpdateProfile.start_link(profile, privkey)
  end

  @doc """
  Get an author's contacts
  """
  @spec subscribe_contacts(list(), PublicKey.id()) :: list()
  def subscribe_contacts(relays, pubkey) do
    case PublicKey.to_binary(pubkey) do
      {:ok, binary_pubkey} ->
        Enum.map(relays, &Socket.subscribe_contacts(__MODULE__, &1, binary_pubkey))

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Follow a new contact using either a binary public key or a npub
  """
  @spec follow(PublicKey.id(), PrivateKey.id()) ::
          {:ok, GenServer.on_start()} | {:error, binary()}
  def follow(pubkey, privkey) do
    with {:ok, binary_privkey} <- PrivateKey.to_binary(privkey),
         {:ok, binary_pubkey} <- PublicKey.to_binary(pubkey) do
      {
        :ok,
        Follow.start_link(RelayManager.active_pids(), binary_pubkey, binary_privkey)
      }
    else
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Unfollow from a contact
  """
  @spec unfollow(PublicKey.id(), PrivateKey.id()) ::
          {:ok, GenServer.on_start()} | {:error, binary()}
  def unfollow(pubkey, privkey) do
    with {:ok, binary_privkey} <- PrivateKey.to_binary(privkey),
         {:ok, binary_pubkey} <- PublicKey.to_binary(pubkey) do
      {
        :ok,
        Unfollow.start_link(RelayManager.active_pids(), binary_pubkey, binary_privkey)
      }
    else
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Get encrypted direct messages from a private key
  """
  @spec encrypted_direct_messages(PrivateKey.id()) :: DynamicSupervisor.on_start_child()
  def encrypted_direct_messages(private_key) do
    case PrivateKey.to_binary(private_key) do
      {:ok, binary_private_key} ->
        DynamicSupervisor.start_child(
          Nostr.Subscriptions,
          {EncryptedDirectMessagesSubscription,
           [RelayManager.active_pids(), binary_private_key, self()]}
        )

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Sends an encrypted direct message
  """
  @spec send_encrypted_direct_messages(PublicKey.id(), String.t(), PrivateKey.id()) ::
          :ok | {:error, String.t()}
  def send_encrypted_direct_messages(remote_pubkey, message, private_key) do
    relay_pids = RelayManager.active_pids()

    Tasks.SendEncryptedDirectMessage.execute(message, remote_pubkey, private_key, relay_pids)
  end

  @doc """
  Get a note by id
  """
  @spec subscribe_note(Note.id()) :: List.t()
  def subscribe_note(note_id), do: subscribe_note(RelayManager.active_pids(), note_id)

  @spec subscribe_note(List.t(), Note.id()) :: List.t()
  def subscribe_note(relays, note_id) do
    case Event.Id.to_binary(note_id) do
      {:ok, binary_note_id} ->
        Enum.map(relays, &Socket.subscribe_note(__MODULE__, &1, binary_note_id))

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Get a list of event of specific kinds
  """
  def subscribe_kinds(kinds), do: subscribe_kinds(RelayManager.active_pids(), kinds)

  @spec subscribe_kinds(list(), list(integer())) ::
          List.t() | {:error, String.t()}
  def subscribe_kinds(relays, kinds) when is_list(kinds) do
    Enum.map(relays, &Socket.subscribe_kinds(__MODULE__, &1, kinds))
  end

  @doc """
  Get a list of author's notes
  """
  @spec subscribe_notes(list() | String.t()) :: list()
  def subscribe_notes(pubkeys) when is_list(pubkeys) do
    RelayManager.active_pids()
    |> subscribe_notes(pubkeys)
  end

  def subscribe_notes(pubkey), do: subscribe_notes([pubkey])

  @spec subscribe_notes(list() | String.t()) ::
          list() | {:error, String.t()}
  def subscribe_notes(relays, pubkeys) when is_list(pubkeys) do
    case PublicKey.to_binary(pubkeys) do
      {:ok, binary_pub_keys} ->
        async_map(relays, &Socket.subscribe_notes(__MODULE__, &1, binary_pub_keys))
      {:error, message} ->
        {:error, message}
    end
  end

  def subscribe_notes(relays, pubkey), do: subscribe_notes(relays, [pubkey])

  @doc """
  Deletes events
  """
  @spec delete_events(list(Note.id()), String.t(), PrivateKey.id()) ::
          {:ok, GenServer.on_start()} | {:error, String.t()}
  def delete_events(note_ids, note, privkey) do
    with {:ok, binary_privkey} <- PrivateKey.to_binary(privkey),
         {:ok, binary_note_ids} <- Event.Id.to_binary(note_ids) do
      {:ok,
       DeleteEvents.start_link(RelayManager.active_pids(), binary_note_ids, note, binary_privkey)}
    else
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Get an author's deletions
  """
  def subscribe_deletions(pubkeys) do
    RelayManager.active_pids()
    |> subscribe_deletions(pubkeys) 
  end

  @spec subscribe_deletions(list(), list()) :: list()
  def subscribe_deletions(relays, pubkeys) when is_list(pubkeys) do
    case PublicKey.to_binary(pubkeys) do
      {:ok, binary_pubkeys} ->
        Enum.map(relays, &Socket.subscribe_deletions(__MODULE__, &1, binary_pubkeys))

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Reposts a note
  """
  @spec repost(Note.id(), PrivateKey.id()) :: {:ok, GenServer.on_start()} | {:error, String.t()}
  def repost(note_id, privkey) do
    with {:ok, binary_privkey} <- PrivateKey.to_binary(privkey),
         {:ok, binary_note_id} <- Event.Id.to_binary(note_id) do
      {:ok, SendRepost.start_link(RelayManager.active_pids(), binary_note_id, binary_privkey)}
    else
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Get an author's reposts
  """
  @spec subscribe_reposts(list()) :: DynamicSupervisor.on_start_child()
  def subscribe_reposts(pubkeys) do
    case PublicKey.to_binary(pubkeys) do
      {:ok, binary_pubkeys} ->
        DynamicSupervisor.start_child(
          Nostr.Subscriptions,
          {RepostsSubscription, [RelayManager.active_pids(), binary_pubkeys, self()]}
        )

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Get an author's reactions
  """
  @spec subscribe_reactions(list(PublicKey.id())) ::
          {:ok, DynamicSupervisor.on_start_child()} | {:error, String.t()}
  def subscribe_reactions(pubkeys) do
    case PublicKey.to_binary(pubkeys) do
      {:ok, binary_pubkeys} ->
        {
          :ok,
          DynamicSupervisor.start_child(
            Nostr.Subscriptions,
            {ReactionsSubscription, [RelayManager.active_pids(), binary_pubkeys, self()]}
          )
        }

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Get an author's realtime timeline including notes from everyone the author follows
  """
  @spec subscribe_timeline(PublicKey.id()) :: DynamicSupervisor.on_start_child()
  def subscribe_timeline(pubkey) do
    case PublicKey.to_binary(pubkey) do
      {:ok, binary_pubkey} ->
        DynamicSupervisor.start_child(
          Nostr.Subscriptions,
          {TimelineSubscription, [RelayManager.active_pids(), binary_pubkey, self()]}
        )

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Sends a note to the relay
  """
  @spec send_note(String.t(), PrivateKey.id()) :: :ok | {:error, String.t()}
  def send_note(note, privkey, relay_pids) do
    Tasks.SendNote.execute(note, privkey, relay_pids)
  end

  def send_note(note, privkey) do
    relay_pids = RelayManager.active_pids()
    send_note(note, privkey, relay_pids)
  end

  @spec react(Note.id(), PrivateKey.id(), String.t()) ::
          {:ok, GenServer.on_start()} | {:error, String.t()}
  def react(note_id, privkey, content \\ "+") do
    with {:ok, binary_privkey} <- PrivateKey.to_binary(privkey),
         {:ok, binary_note_id} <- Event.Id.to_binary(note_id) do
      {
        :ok,
        SendReaction.start_link(
          RelayManager.active_pids(),
          binary_note_id,
          binary_privkey,
          content
        )
      }
    else
      {:error, message} -> {:error, message}
    end
  end

  def subscriptions() do
    Socket.subscriptions(self())
  end

  def unsubscribe(pid) do
    DynamicSupervisor.terminate_child(Nostr.Subscriptions, pid)
    #    GenServer.call(pid, {:terminate, :shutdown})
  end

  @doc """
  From WitchCraft: https://github.com/witchcrafters/witchcraft/blob/main/lib/witchcraft/functor.ex#L204
  """
  def async_map(functor, fun) do
    functor
    |> Enum.map(fn item ->
      Task.async(fn -> fun.(item) end)
    end)
    |> Enum.map(&Task.await/1)
  end

  def print_to_console(%{id: id, created_at: created_at, content: content, pubkey: pubkey}) do
    IO.puts("""
      ####### EVENT #{id}
      ## seen at: #{created_at}
      ## > #{content}
      ## from: #{NostrBasics.Keys.PublicKey.to_npub(pubkey)}
      """)
  end
end
