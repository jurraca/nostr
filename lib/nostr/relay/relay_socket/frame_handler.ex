defmodule Nostr.Relay.Socket.FrameHandler do
  @moduledoc """
  Websocket frames are first sent here to be decoded and then sent to the frame dispatcher
  """

  alias NostrBasics.Message
  require Logger

  def handle_text_frame(frame, relay_url, owner_pid) do
    frame
    |> Message.parse()
    |> handle_message(relay_url, owner_pid)
  end

  defp handle_message({:event, subscription_id, _} = message, _relay_url, _owner_pid) do
    Logger.info("received event for sub_id #{String.to_atom(subscription_id)}")

    subscription_id
    |> String.to_atom()
    |> registry_dispatch(message)
  end

  defp handle_message({:notice, message}, relay_url, _owner_pid) do
    Logger.info("NOTICE from #{relay_url}: #{message}")
    registry_dispatch(:notice, message)
  end

  defp handle_message(
         {:end_of_stored_events, subscription_id},
         relay_url,
         _owner_pid
       ) do
    message = {:end_of_stored_events, relay_url, subscription_id}

    subscription_id
    |> String.to_atom()
    |> registry_dispatch(message)
  end

  defp handle_message({:ok, event_id, message}, relay_url, owner_pid) do
    Logger.info("OK event #{event_id} from #{relay_url}")
    registry_dispatch(:ok, message)
  end

  defp handle_message({:error, event_id, message}, relay_url, owner_pid) do
    Logger.error(message)
    registry_dispatch(:error, message)
  end

  defp handle_message({:unknown, message}, relay_url, _) do
    registry_dispatch(:error, "Unknown message received from #{relay_url}: #{message}")
  end

  defp handle_message({:json_error, message}, relay_url, owner_pid) do
    Logger.error(message)
  end

  @doc """
  Send a message to a given pubsub topic
  """
  def registry_dispatch(sub_id, message) when is_atom(sub_id) do
    Registry.dispatch(Registry.PubSub, sub_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end
end
