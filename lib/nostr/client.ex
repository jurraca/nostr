defmodule Nostr.Client do
  @moduledoc """
  Implementation of a Nostr Client: subscribe to relays, modify subscriptions, send events.
  The Client matches the publish-subscribe model which Nostr is built on. After creating a subscription via the Client.Request module and subscribing to one or multiple relays, incoming messages will be broadcast via the Registry.PubSub, where the subscription ID is the topic we broadcast on. Implementation of a listener is left to the user of the library--they are regular Elixir messages.
  """

  require Logger

  alias Nostrlib.Keys.{PublicKey, PrivateKey}
  alias Nostrlib.{Event, Profile, Note}

  alias Nostr.Client.{Request, Send, Subscriptions}
  alias Nostr.Relay.{RelayManager, Socket}

  @doc """
  Load relays and/or filters.
  These are taken from app configuration. Filters can be omitted on startup,
  but if you set `connect_on_startup: true` in `config.exs`, you must pass relays to connect to.
  """
  def load_configuration(%{relays: [], filters: _}) do
    {:error,
     "No relays provided. Please add a relay so the client can send and/or receive stuff."}
  end

  def load_configuration(%{relays: relays, filter: []}) do
    add_relays(relays)
  end

  def load_configuration(%{relays: relays, filters: filters}) do
    relays = add_relays(relays)

    case Subscriptions.subscribe(filters, relays) do
      {:ok, sub_ids} ->
        Logger.info("Loaded configuration relays and subscription IDs.")
        {:ok, sub_ids}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Connect to a relay via its URL.
  """
  def add_relay(relay_url) do
    case RelayManager.add(relay_url) do
      {:ok, _pid} = res -> res
      {:error, _} = err -> err
      _ -> {:error, "Couldn't add relay #{relay_url}"}
    end
  end

  @doc """
  Connect to multiple relays, only return successfully started PIDs.
  """
  def add_relays(relays) when is_list(relays) do
    relays
    |> Enum.map(&add_relay/1)
    |> Enum.map(fn
      {:ok, pid} ->
        pid

      {:error, msg} ->
        Logger.error(msg)
        false

      _ ->
        false
    end)
    |> Enum.filter(& &1)
  end

  @doc """
  After creating a sub, Request.new/1 returns a subscription ID, which the calling process can use to subscribe to a topic/subscription.
  """
  def subscribe_to_topic(pubsub, sub_id), do: Registry.register(pubsub, sub_id, [])

  @doc """
  Send a signed and encoded event via the specified relays.
  send_event/2 is a GenServer cast, and always returns :ok, so we don't handle the response.
  """
  def send_event(encoded_event, relay_pids) do
    Enum.map(relay_pids, fn pid -> Socket.send_event(pid, encoded_event) end)
    :ok
  end

  @doc """
  Sends a text note via relays
  """
  @spec send_note(String.t(), PrivateKey.id()) :: :ok | {:error, String.t()}
  def send_note(note, privkey) do
    relay_pids = RelayManager.active_pids()
    send_note(note, privkey, relay_pids)
  end

  def send_note(note, privkey, relay_pids) do
    case %Note{content: note}
      |> Event.create(privkey)
      |> Event.sign_and_serialize(privkey) do
        {:ok, json_event} -> send_event(json_event, relay_pids)
        _ -> {:error, "Invalid event submitted for note \"#{note}\" "}
    end
  end

  @doc """
  Follow a new contact using either a binary public key or a npub
  """
  @spec follow(PublicKey.id(), List.t(), PrivateKey.id()) ::
          {:ok, GenServer.on_start()} | {:error, binary()}
  def follow(pubkey, contact_list, privkey) do
    with  {:ok, binary_pubkey} <- PublicKey.to_binary(pubkey),
      relay_pids <- RelayManager.active_pids(),
      contact_list <- ContactList.add(contact_list, binary_pubkey) do
      case contact_list |> Event.create() |> Event.sign_and_serialize(privkey) do
        {:ok, signed_event} -> send_event(signed_event, relay_pids)
        {:error, err} -> {:error, err}
      end
    else
      err -> err
    end
  end

  @doc """
  Unfollow from a contact
  """
  @spec unfollow(PublicKey.id(), List.t(), PrivateKey.id()) ::
          {:ok, GenServer.on_start()} | {:error, binary()}
  def unfollow(pubkey, contact_list, privkey) do
    with {:ok, binary_privkey} <- PrivateKey.to_binary(privkey),
         {:ok, binary_pubkey} <- PublicKey.to_binary(pubkey) do
      {
        :ok,
        Send.unfollow(binary_pubkey, binary_privkey, contact_list, RelayManager.active_pids())
      }
    else
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Send reaction to a given note.
  """
  @spec react(Note.id(), PrivateKey.id(), String.t()) ::
          {:ok, GenServer.on_start()} | {:error, String.t()}
  def react(note_id, privkey, content \\ "+") do
    with {:ok, binary_privkey} <- PrivateKey.to_binary(privkey),
         {:ok, binary_note_id} <- Event.Id.to_binary(note_id) do
      {
        :ok,
        Send.reaction(
          content,
          binary_note_id,
          binary_privkey,
          RelayManager.active_pids()
        )
      }
    else
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Update the profile that's linked to the private key
  """
  @spec update_profile(Profile.t(), PrivateKey.id()) :: :ok | {:error, String.t()}
  def update_profile(%Profile{} = profile, privkey) do
    relays = RelayManager.active_pids()
    case profile |> Event.create() |> Event.sign_and_serialize(privkey) do
        {:ok, event} -> send_event(event, relays)
        {:error, err} -> {:error, err}
    end
  end

    @doc """
  Unsubscribe from all subscriptions on a given relay PID.
  """
  def unsubscribe(pid) do
    pid
    |> Socket.subscriptions()
    |> Enum.map(&Socket.unsubscribe(pid, &1))
  end

  @doc """
  Unsubscribe from all subs on all relays. Does NOT close the websocket conn.
  """
  def unsubscribe_all() do
    RelayManager.active_pids() |> Enum.map(&unsubscribe/1)
  end

  def close(subscription_id, relay_pids) do
    Enum.map(relay_pids, &Socket.unsubscribe(&1, subscription_id))
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
    ## from: #{PublicKey.to_npub(pubkey)}
    """)
  end
end
