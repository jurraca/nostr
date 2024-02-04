defmodule Nostr.Client.Send do
  @moduledoc """
  Send events. Anything that's not a "REQ" probably goes here.
  """
  require Logger

  alias Nostrlib.Keys.PublicKey
  alias Nostrlib.{ContactList, Event, Note, Profile, Reaction, Repost}

  alias Nostr.Relay.Socket

  def event(contents, private_key, relay_pids) do
    with {:ok, pubkey} <- PublicKey.from_private_key(private_key),
         {:ok, event} <- Event.create(1, contents, pubkey),
         {:ok, signed_event} <- Event.sign_and_serialize(event, private_key) do
      case Event.validate_event(signed_event) do
        true -> Client.send_event(signed_event, relay_pids)
        {:error, _} = err -> err
      end
    else
      {:error, message} -> {:error, message}
    end
  end

  def reaction(event, privkey, content, relay_pids) do
    with {:ok, pubkey} <- PublicKey.from_private_key(privkey),
         {:ok, reaction_event} <-
           Reaction.to_event(
             %Reaction{event_id: event.id, event_pubkey: event.pubkey},
             pubkey
           ),
         {:ok, signed_event} <-
           %Event{reaction_event | content: content, created_at: DateTime.utc_now()}
           |> Event.add_id()
           |> Event.sign_event(privkey) do
      validate_and_send(signed_event, relay_pids)
    else
      {:error, message} -> {:error, message}
    end
  end

  def repost(event, found_on_relay, privkey, relay_pids) do
    with {:ok, pubkey} <- PublicKey.from_private_key(privkey),
         {:ok, repost} <-
           %Repost{event: event, relays: [found_on_relay]}
           |> Repost.to_event(pubkey),
         {:ok, signed_event} <- Event.sign_event(repost, privkey) do
      validate_and_send(signed_event, relay_pids)
    else
      {:error, message} -> {:error, message}
    end
  end

  def unfollow(unfollow_pubkey, privkey, contact_list, relay_pids) do
    with contact_list <-
           ContactList.remove(contact_list, unfollow_pubkey) |> ContactList.to_event(),
         {:ok, signed_event} <- Event.create(contact_list) |> Event.sign_and_serialize(privkey) do
      validate_and_send(signed_event, relay_pids)
    else
      {:error, message} -> {:error, message}
    end
  end

  defp validate_and_send(signed_event, relay_pids) do
    case Event.validate_event(signed_event) do
      true -> Client.send_event(signed_event, relay_pids)
      {:error, _} = err -> err
    end
  end
end
