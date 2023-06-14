defmodule Nostr.Client.Request do
  @moduledoc """
  Transforms simple functions into JSON requests that relays can interpret
  """

  alias NostrBasics.Filter
  alias NostrBasics.Filter.Serializer

  @default_id_size 16
  @default_since 36 # hours back for messages

  @metadata_kind 0
  @text_kind 1
  @recommended_servers_kind 2
  @contacts_kind 3
  @encrypted_direct_message_kind 4
  @deletion_kind 5
  @repost_kind 6
  @reaction_kind 7

  def profile(pubkey) do
    get_by_authors([pubkey], [@metadata_kind], nil)
  end

  def recommended_servers() do
    get_by_authors([], [@recommended_servers_kind], nil)
  end

  def contacts(pubkey, limit) do
    get_by_authors([pubkey], [@contacts_kind], limit)
  end

  def note(id) do
    get_by_ids([id], @text_kind)
  end

  # fix and use NostrBasics.to_query/1
  def all(limit \\ 10) do
    # got to specify kinds, or else, some relays won't return anything
    new(%Filter{kinds: [1, 5, 6, 7, 9735], since: since(@default_since), limit: limit})
  end

  def kinds(kinds, limit \\ 10) when is_list(kinds) do
    new(%Filter{kinds: kinds, since: since(@default_since), limit: limit})
  end

  def notes(pubkeys, limit \\ 10) when is_list(pubkeys) do
    get_by_authors(pubkeys, [@text_kind], limit)
  end

  def deletions(pubkeys, limit \\ 10) when is_list(pubkeys) do
    get_by_authors(pubkeys, [@deletion_kind], limit)
  end

  def reposts(pubkeys, limit \\ 10) when is_list(pubkeys) do
    get_by_authors(pubkeys, [@repost_kind], limit)
  end

  def reactions(pubkeys, limit \\ 10) when is_list(pubkeys) do
    get_by_authors(pubkeys, [@reaction_kind], limit)
  end

  def encrypted_direct_messages(<<_::256>> = pubkey, limit \\ 10) do
    get_by_kind(@encrypted_direct_message_kind, [pubkey], limit)
  end

  defp get_by_authors(pubkeys, kinds, limit) do
    pubkeys
    |> filter_by_authors(kinds, limit)
    |> new()
  end

  defp get_by_kind(kind, pubkeys, limit) do
    kind
    |> filter_by_kind(pubkeys, limit)
    |> new()
  end

  defp get_by_ids(ids, kind) do
    ids
    |> filter_by_ids(kind, 1)
    |> new()
  end

  defp filter_by_kind(kind, pubkeys, limit) do
    %Filter{
      kinds: [kind],
      p: hexify(pubkeys),
      limit: limit
    }
  end

  defp filter_by_ids(ids, kind, limit) do
    %Filter{
      ids: hexify(ids),
      kinds: [kind],
      limit: limit
    }
  end

  defp filter_by_authors(pubkeys, kinds, limit) when is_integer(limit) do
    %Filter{
      authors: hexify(pubkeys),
      kinds: kinds,
      since: since(@default_since),
      limit: limit
    }
  end

  defp filter_by_authors(pubkeys, kinds, _) do
    %Filter{
      authors: hexify(pubkeys),
      kinds: kinds
    }
  end

  @doc """
  For a given Filter struct, encode a request and a request/subscription ID
  """
  def new(filter) do
    filter = cast_to_struct(filter)
    request_id = generate_random_id()
    atom_request_id = String.to_atom(request_id)
    encoded_req = format_request(request_id, filter)
    {atom_request_id, encoded_req}
  end

  def new(_), do: {:error, "Filters must be created from a %NostrBasics.Filter{} struct."}

  def format_request(id, %Filter{} = filter) do
    case validate_filter(filter) do
      {:ok, _} -> Jason.encode!(["REQ", id, filter])
      {:error, _} = err -> err
    end
  end

  def format_request(id, filter) when is_binary(filter) do
    dec = Jason.decode!(filter)
    Jason.encode!(["REQ", id, dec])
  end

  def cast_to_struct(filter) do
    params = filter |> Map.from_struct() |> Map.to_list()
    struct(%Filter{}, params)
  end

  @spec generate_random_id(integer()) :: binary()
  defp generate_random_id(size \\ @default_id_size) do
    :crypto.strong_rand_bytes(size) |> Binary.to_hex()
  end

  defp since(hours) when is_integer(hours) do
    DateTime.from_unix!(DateTime.to_unix(DateTime.utc_now()) - (3600 * hours))
  end

  # a filter should always have kinds, since, and limit
  # validate values for all three, if all true, serialize
  defp validate_filter(%{kinds: k, since: s, limit: l} = filter) do
    case [Enum.count(k) > 0, is_integer(l)]
    |> Enum.all?(&(&1)) do
      true -> Serializer.to_req(filter)
      false -> {:error, "Your filter must specify kinds, since and limit parameters."}
    end
  end

  defp validate_filter(filter) do
    keys = filter |> Map.keys() |> Enum.join(", ")
    {:error, "Filter missing required keys: existing keys are #{keys}"}
  end

  defp hexify(keys) when is_list(keys) do
    Enum.map(keys, &Binary.to_hex(&1))
  end
end
