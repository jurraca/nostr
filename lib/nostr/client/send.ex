defmodule Nostr.Client.Send do
  require Logger

  alias NostrBasics.Event
  alias NostrBasics.Event.{Signer, Validator}
  alias NostrBasics.Keys.PublicKey
  alias NostrBasics.Models.{ContactList, Profile, Reaction}

  alias Nostr.Relay.Socket

  def prepare_and_sign_event(event, private_key) do
    %Event{event | created_at: DateTime.utc_now()}
    |> Event.add_id()
    |> Signer.sign_event(private_key)
  end

  def send_event(validated_event, relay_pids) do
    for relay_pid <- relay_pids do
      Socket.send_event(relay_pid, validated_event)
    end
  end

  def update_profile(%Profile{} = new_profile, private_key, relay_pids) do
    with {:ok, pubkey} <- PublicKey.from_private_key(private_key),
         {:ok, profile_event} <- create_profile_event(new_profile, pubkey),
         {:ok, signed_event} <- prepare_and_sign_event(profile_event, private_key) do
      :ok = Validator.validate_event(signed_event)

      send_event(signed_event, relay_pids)

      :ok
    else
      {:error, message} -> {:error, message}
    end
  end

  def create_profile_event(%Profile{} = profile, pubkey) do
    Profile.to_event(profile, pubkey)
  end

  def reaction(event, privkey, content, relay_pids) do
    pubkey = PublicKey.from_private_key!(privkey)

    {:ok, reaction_event} =
      %Reaction{event_id: event.id, event_pubkey: event.pubkey}
      |> Reaction.to_event(pubkey)

    {:ok, signed_event} =
      %Event{reaction_event | content: content, created_at: DateTime.utc_now()}
      |> Event.add_id()
      |> Signer.sign_event(privkey)

    case Validator.validate_event(signed_event) do
      :ok -> send_event(signed_event, relay_pids)
      {:error, _} = err -> err
    end
  end

  def follow(follow_pubkey, privkey, %ContactList{} = contact_list, relay_pids) do
    contact_list_event =
      ContactList.add(contact_list, follow_pubkey)
      |> ContactList.to_event()

    {:ok, signed_event} =
      %Event{contact_list_event | created_at: DateTime.utc_now()}
      |> Event.add_id()
      |> Signer.sign_event(privkey)

    case Validator.validate_event(signed_event) do
      :ok -> send_event(signed_event, relay_pids)
      {:error, _} = err -> err
    end
  end

  def unfollow(unfollow_pubkey, privkey, contact_list, relay_pids) do
    contact_list =
      ContactList.remove(contact_list, unfollow_pubkey)
      |> ContactList.to_event()

    {:ok, signed_event} =
      %Event{contact_list | created_at: DateTime.utc_now()}
      |> Event.add_id()
      |> Signer.sign_event(privkey)

      case Validator.validate_event(signed_event) do
        :ok -> send_event(signed_event, relay_pids)
        {:error, _} = err -> err
      end
  end
end
