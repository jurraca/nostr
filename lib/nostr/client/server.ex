defmodule Nostr.Client.Server do
  use WebSockex
  require Logger

  alias Nostr.Event

  @impl true
  def handle_connect(_conn, %{client_pid: client_pid} = state) do
    Logger.info("Connected to relay...")

    send(client_pid, :connected)

    {:ok, state}
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    {:reply, {:text, message}, state}
  end

  @impl true
  def handle_frame({type, msg}, %{client_pid: client_pid} = state) do
    case type do
      :text ->
        {_request_id, event} =
          msg
          |> Jason.decode!()
          |> Event.dispatch()

        send(client_pid, event)

      _ ->
        Logger.warn("#{type}: unknown type of frame")
    end

    {:ok, state}
  end
end
