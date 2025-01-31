defmodule Nostr.Client.Send do
  @moduledoc """
  Send events. Anything that's not a "REQ" probably goes here.
  """
  require Logger

  alias NostrBasics.Event
  alias NostrBasics.Event.{Signer, Validator}
  alias NostrBasics.Keys.PublicKey
  alias NostrBasics.Models.{ContactList, EncryptedDirectMessage, Note, Profile, Reaction, Repost}

  alias Nostr.Relay.Socket

  def format_event(signed_event) do
    Jason.encode(["EVENT", signed_event])
  end

  def close(subscription_id) do
    Jason.encode(["CLOSE", subscription_id])
  end

  def prepare_and_sign_event(event, private_key) do
    %Event{event | created_at: DateTime.utc_now()}
    |> Event.add_id()
    |> Signer.sign_event(private_key)
  end

  def send_event(validated_event, relay_pids) do
    for relay_pid <- relay_pids do
      Socket.send_event(relay_pid, validated_event)
    end

    :ok
  end

  @doc """
  Sends a note via a list of relays

  ## Examples
      iex> private_key = <<0x4E22DA43418DD934373CBB38A5AB13059191A2B3A51C5E0B67EB1334656943B8::256>>
      ...> relay_pids = []
      ...> "The Times 03/Jan/2009 Chancellor on brink of second bailout for banks"
      ...> |> Nostr.Client.Tasks.SendNote.execute(private_key, relay_pids)
      :ok
  """
  @spec note(String.t(), PrivateKey.id(), list()) :: :ok | {:error, String.t()}
  def note(contents, private_key, relay_pids) do
    with {:ok, pubkey} <- PublicKey.from_private_key(private_key),
         {:ok, event} <- create_note_event(contents, pubkey),
         {:ok, signed_event} <- prepare_and_sign_event(event, private_key) do
      validate_and_send(signed_event, relay_pids)
    else
      {:error, message} -> {:error, message}
    end
  end

  def create_note_event(contents, private_key) do
    Note.to_event(%Note{content: contents}, private_key)
  end

  def create_profile_event(%Profile{} = profile, pubkey) do
    Profile.to_event(profile, pubkey)
  end

  def update_profile(%Profile{} = new_profile, private_key, relay_pids) do
    with {:ok, pubkey} <- PublicKey.from_private_key(private_key),
         {:ok, profile_event} <- create_profile_event(new_profile, pubkey),
         {:ok, signed_event} <- prepare_and_sign_event(profile_event, private_key) do
      validate_and_send(signed_event, relay_pids)
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
           |> Signer.sign_event(privkey) do
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
         {:ok, signed_event} <- prepare_and_sign_event(repost, privkey) do
      validate_and_send(signed_event, relay_pids)
    else
      {:error, message} -> {:error, message}
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

    validate_and_send(signed_event, relay_pids)
  end

  def unfollow(unfollow_pubkey, privkey, contact_list, relay_pids) do
    with contact_list <-
           ContactList.remove(contact_list, unfollow_pubkey) |> ContactList.to_event(),
         {:ok, signed_event} <-
           %Event{contact_list | created_at: DateTime.utc_now()}
           |> Event.add_id()
           |> Signer.sign_event(privkey) do
      validate_and_send(signed_event, relay_pids)
    else
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Encrypt and send a direct message

  ## Examples
      iex> remote_pubkey = <<0xefc83f01c8fb309df2c8866b8c7924cc8b6f0580afdde1d6e16e2b6107c2862c::256>>
      ...> private_key = <<0x4E22DA43418DD934373CBB38A5AB13059191A2B3A51C5E0B67EB1334656943B8::256>>
      ...> relay_pids = []
      ...> "The Times 03/Jan/2009 Chancellor on brink of second bailout for banks"
      ...> |> encrypted_dm(remote_pubkey, private_key, relay_pids)
      :ok
  """
  @spec encrypted_dm(String.t(), PublicKey.id(), PrivateKey.id(), list()) ::
          :ok | {:error, String.t()}
  def encrypted_dm(contents, remote_pubkey, private_key, relay_pids) do
    with {:ok, dm_event} <- create_dm_event(contents, remote_pubkey, private_key),
         {:ok, signed_event} <- prepare_and_sign_event(dm_event, private_key) do
      validate_and_send(signed_event, relay_pids)
    else
      {:error, message} -> {:error, message}
    end
  end

  defp create_dm_event(contents, remote_pubkey, private_key) do
    EncryptedDirectMessage.to_event(
      %EncryptedDirectMessage{content: contents, remote_pubkey: remote_pubkey},
      private_key
    )
  end

  defp validate_and_send(signed_event, relay_pids) do
    case Validator.validate_event(signed_event) do
      :ok -> send_event(signed_event, relay_pids)
      {:error, _} = err -> err
    end
  end
end
