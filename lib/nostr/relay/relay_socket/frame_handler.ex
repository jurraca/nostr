defmodule Nostr.Relay.Socket.FrameHandler do
  @moduledoc """
  Websocket frames are first sent here to be decoded and then sent to the frame dispatcher
  """

  alias NostrBasics.RelayMessage
  require Logger

  def handle_text_frame(frame, relay_url, owner_pid) do
    frame
    |> RelayMessage.parse()
    |> handle_message(relay_url, owner_pid)
  end

  defp handle_message({:event, subscription_id, _} = event, _relay_url, _owner_pid) do
    Logger.info("received event for sub_id #{String.to_atom(subscription_id)}")
    sub_id_atom = String.to_atom(subscription_id)
    Registry.dispatch(Registry.PubSub, sub_id_atom, fn entries ->
      for {pid, _} <- entries, do: send(pid, event)
    end)
  end

  defp handle_message({:notice, message}, relay_url, _owner_pid) do
    Logger.info("NOTICE from #{relay_url}: #{message}")
    Registry.dispatch(Registry.PubSub, "notice", fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
#    send(owner_pid, {:console, :notice, %{url: relay_url, message: message}})
  end

  defp handle_message(
         {:end_of_stored_events, subscription_id},
         relay_url,
         _owner_pid
       ) do
    message = {:end_of_stored_events, relay_url, subscription_id}

    sub_id = String.to_atom(subscription_id)
    Registry.dispatch(Registry.PubSub, sub_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end

  defp handle_message({:ok, event_id, success?, message}, relay_url, owner_pid) do
    info = %{url: relay_url, event_id: event_id, success?: success?, message: message}
    send(owner_pid, {:console, :ok, info})
  end

  defp handle_message({:unknown, message}, relay_url, owner_pid) do
    send(owner_pid, {:console, :unknown_relay_message, url: relay_url, message: message})
  end

  defp handle_message({:json_error, message}, relay_url, owner_pid) do
    send(owner_pid, {:console, :malformed_json_relay_message, url: relay_url, message: message})
  end
end
