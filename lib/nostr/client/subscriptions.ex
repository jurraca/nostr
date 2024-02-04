defmodule Nostr.Client.Subscriptions do
    @moduledoc """
    List, query, and send subscriptions.
    """

    alias NostrBasics.Request
    alias Nostr.Relay.RelayManager

    @doc """
    Get the subscriptions that a process is subscribed to.
    Useful for seeing which subs a Client is currently listening to.
    """
    def get(pid), do: Registry.keys(Registry.PubSub, pid)

    @doc """
    Get subscriptions for all active relays.
    Each Relay GenServer maintains a state of its own subscriptions, and deletes them on unsubscribe.
    Useful to know which relay has which subscriptions.
    """
    def get_all do
      RelayManager.active_pids()
      |> Enum.map(&get(&1))
      |> List.flatten()
    end

    @doc """
    Get an author's profile
    Takes an npub.
    """
    def profile(pubkey), do: profile(pubkey, RelayManager.active_pids() )

    @spec profile(List.t(), PublicKey.id()) :: List.t() | {:error, String.t()}
    def profile(pubkey, relays) when is_list(relays) do
      case PublicKey.to_binary(pubkey) do
        {:ok, binary_pubkey} ->
            binary_pubkey
            |> Request.profile()
            |> send_filter(relays)

        {:error, message} ->
          {:error, message}
      end
    end

    @doc """
    Get an author's recommended servers
    """
    def recommended_servers(pubkey),
      do: recommended_servers(RelayManager.active_pids())

    @spec recommended_servers(String.t(), List.t()) :: List.t()
    def recommended_servers(pubkey, relays) do
      send_filter(Request.recommended_servers(), relays)
    end

    @doc """
    Get an author's contacts
    """
    @spec contacts(list(), PublicKey.id()) :: {:ok, String.t()} | {:error, String.t()}
    def contacts(relays, pubkey) do
      case PublicKey.to_binary(pubkey) do
        {:ok, binary_pubkey} ->
          send_filter(Request.contacts(binary_pubkey), relays)

        {:error, message} ->
          {:error, message}
      end
    end

  @doc """
  Subscribe to multiple filters and relays.
  Useful to load an existing  Nostr profile.
  Subscriptions are "fire and forget", so we return subscription IDs in order for the client to subscribe to them.
  """
  def subscribe(filters, relays, acc \\ [])

  def subscribe([head | tail], relays, acc) do
    case request_from_filter(head) do
      {:ok, req} -> subscribe(tail, relays, [req] ++ acc)
      {:error, _} = err -> err
    end
  end

  # finish tail recursion, subscribe the individual {id, filter} tuples
  # and return ids, deduplicated.
  def subscribe([], relays, acc) do
    sub_ids =
      acc
      |> Enum.map(&send_filter(&1, relays))
      |> Enum.map(fn
        {:ok, req_id} ->
          req_id

        {:error, msg} ->
          Logger.error(msg)
          false
      end)
      |> Enum.filter(& &1)
      |> Enum.uniq()

    {:ok, sub_ids}
  end

  @doc """
  Subscribe to a single filter, via all active relay PIDs.
  """
  def send_filter({_req_id, _filter} = req) do
    relays = RelayManager.active_pids()
    send_filter(req, relays)
  end

  @doc """
  Subscribe to a filter via a specific set of relays.
  Returns {:ok, sub_id} if successful.
  """
  def send_filter({req_id, filter}, relays) when is_binary(filter) do
    Logger.info("Subscribing to #{Enum.count(relays)} relays for filter #{filter}")

    case relays |> Enum.map(&Socket.subscribe(&1, req_id, filter)) |> Enum.all?() do
      true ->
        {:ok, req_id}

      # TODO: return which were successful and which were not
      false ->
        {:error, "Not all subscriptions were successful for req_id#{Atom.to_string(req_id)}"}
    end
  end

  @doc """
  Pass an existing %Filter{} struct and create a Request out of it.
  Returns {:ok, {sub_id, encoded_req}}
  """
  def request_from_filter(filter) do
    try do
      {:ok, Request.new(filter)}
    rescue
      _ -> {:error, "Creating Request for filter id #{filter.id} failed."}
    end
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
        binary_note_id
        |> Request.note()
        |> send_filter(relays)

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Get a list of event of specific kinds
  """
  def subscribe_kinds(kinds), do: RelayManager.active_pids() |> subscribe_kinds(kinds)

  @spec subscribe_kinds(list(), list(integer())) ::
          List.t() | {:error, String.t()}
  def subscribe_kinds(relays, kinds) when is_list(kinds) do
    Request.kinds(kinds) |> send_filter(relays)
  end

  @doc """
  Get a list of author's notes
  """
  @spec subscribe_notes(list() | String.t()) :: list() | {:error, String.t()}
  def subscribe_notes(pubkeys) when is_list(pubkeys) do
    RelayManager.active_pids() |> subscribe_notes(pubkeys)
  end

  def subscribe_notes(pubkey), do: subscribe_notes([pubkey])

  def subscribe_notes(relays, pubkeys) when is_list(pubkeys) do
    case PublicKey.to_binary(pubkeys) do
      {:ok, binary_pub_keys} ->
        binary_pub_keys
        |> Request.notes()
        |> send_filter(relays)

      {:error, message} ->
        {:error, message}
    end
  end
  @doc """
  Subscribe to all messages. DANGER: TSUNAMI RISK
  """
  def all, do: RelayManager.active_pids() |> all()
  def all(relays), do: Request.all() |> send_filter(relays)
end