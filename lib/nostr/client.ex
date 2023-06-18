defmodule Nostr.Client do
  @moduledoc """
  Connects to a relay through websockets
  """

  require Logger

  alias NostrBasics.Event
  alias NostrBasics.Keys.{PublicKey, PrivateKey}
  alias NostrBasics.Models.{Profile, Note}

  alias Nostr.Relay.{RelayManager, Socket}
  alias Nostr.Client.Tasks
  alias Nostr.Client.Request

  alias Registry.PubSub

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

  def load_configuration(%{relays: relays, filters: []}) do
    {:error, "No filters provided. Please create a filter before connecting to relays."}
  end

  def load_configuration(%{relays: relays, filters: filters}) do
    relays = add_relays(relays)
    case subscribe(filters, relays) do
      {:ok, sub_ids} ->
        Logger.info("Loaded configuration relays and subscription IDs.")
        {:ok, sub_ids}
      {:error, _} = err -> err
    end
  end

  def subscribe_to_topic(pubsub, sub_id) do
    Registry.register(pubsub, sub_id, [])
  end

  def add_relay(relay_url) do
    case RelayManager.add(relay_url) do
      {:ok, _pid} = res -> res
      {:error, _} = err -> err
      _ -> {:error, "Couldn't add relay #{relay_url}"}
    end
  end

  # Connect to relays, only return successfully started PIDs.
  def add_relays(relays) when is_list(relays) do
    relays
      |> Enum.map(&add_relay/1)
      |> Enum.map(fn
        {:ok, pid} -> pid
        {:error, msg} ->
          Logger.error(msg)
          false
        _ -> false
      end)
      |> Enum.filter(&(&1))
  end

  def subscribe(filters, relays, acc \\ [])

  # Multiple filters
  def subscribe([head | tail], relays, acc) do
    case request_from_filter(head) do
      {:ok, req} -> subscribe(tail, relays, [req] ++ acc)
      {:error, _} = err -> err
    end
  end

  # finish tail recursion, subscribe the individual {id, filter} tuples
  # and return ids, deduplicated.
  def subscribe([], relays, acc) do
    sub_ids = acc
      |> Enum.map(&subscribe_filter(&1, relays))
      |> Enum.map(fn
        {:ok, req_id} -> req_id
        {:error, msg} ->
            Logger.error(msg)
            false
      end)
      |> Enum.filter(&(&1))
      |> Enum.uniq()

    {:ok, sub_ids}
  end

  # Single filter, default to all active relays
  def subscribe_filter({_req_id, _filter} = req) do
    relays = Nostr.Relay.RelayManager.active_pids()
    subscribe_filter(req, relays)
  end

  # Single filter, subscribe to all relays
  # Socket.subscribe is a genserver cast, so we don't wait for an answer
  def subscribe_filter({_req_id, filter}, []) when is_binary(filter) do
    {:error, "Relays list is empty: no relays to subscribe to."}
  end

  def subscribe_filter({req_id, filter}, relays) when is_binary(filter) do
    Logger.info("Subscribing with #{Enum.count(relays)} relays for filter #{filter}")
    Enum.map(relays, &Socket.subscribe(&1, req_id, filter))
    {:ok, req_id}
  end

  def request_from_filter(filter) do
    try do
      {:ok, Request.new(filter)}
    rescue
      _ -> {:error, "Creating Request for filter id #{filter.id} failed."}
    catch
      {req_id, encoded_filter} -> subscribe_filter({req_id, encoded_filter})
    end
  end

  def get_subscriptions(pid) do
    Registry.keys(Registry.PubSub, pid)
  end

  def get_subscriptions_all() do
    RelayManager.active_pids()
    |> Enum.map(&get_subscriptions(&1))
    |> List.flatten()
  end

  @impl true
  def handle_info({:event, _sub_id, %NostrBasics.Event{}} = event, %{pubsub: pubsub} = state) do
    #Registry.PubSub.dispatch(pubsub, "events:", event)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg, label: "client info msg")
    {:noreply, state}
  end

  def subscribe_all(), do: subscribe_all(RelayManager.active_pids())

  def subscribe_all(relays), do: subscribe(Request.all(), relays)

  @doc """
  Get an author's profile
  Takes an npub.
  """
  def subscribe_profile(pubkey), do: subscribe(RelayManager.active_pids(), pubkey)

  @spec subscribe_profile(List.t(), PublicKey.id()) :: List.t() | {:error, String.t()}
  def subscribe_profile(relays, pubkey) when is_list(relays) do
    case PublicKey.to_binary(pubkey) do
      {:ok, binary_pubkey} ->
        Enum.map(relays, &subscribe(Request.profile(binary_pubkey), &1))

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Get an author's recommended servers
  """
  def subscribe_recommended_servers(), do: subscribe_recommended_servers(RelayManager.active_pids())

  @spec subscribe_recommended_servers() :: List.t()
  def subscribe_recommended_servers(relays) do
    Enum.map(relays, &subscribe(Request.recommended_servers(), &1))
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
    Enum.map(relays, &subscribe(Request.kinds(kinds), &1))
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
        async_map(relays, &subscribe(Request.notes(binary_pub_keys), &1))
      {:error, message} ->
        {:error, message}
    end
  end

  def subscribe_notes(relays, pubkey), do: subscribe_notes(relays, [pubkey])

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

  def unsubscribe(pid) do
    pid
    |> Socket.subscriptions()
    |> Enum.map(&Socket.unsubscribe(pid, &1))
  end

  def unsubscribe_all() do
    RelayManager.active_pids() |> Enum.map(&unsubscribe/1)
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

  @spec generate_random_id(integer()) :: binary()
  defp generate_random_id(size \\ 16) do
    :crypto.strong_rand_bytes(size) |> Binary.to_hex()
  end
end
