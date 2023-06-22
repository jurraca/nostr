defmodule Nostr.Relay.Socket.Server do
  @moduledoc """
  The process handling all of the Socket commands
  """

  use GenServer

  require Logger

  alias Nostr.Relay.Socket
  alias Nostr.Relay.Socket.{Connector, MessageDispatcher, Publisher, Sender}
  alias Nostr.Client.{SendRequest}

  @impl true
  def init(%{relay_url: relay_url, owner_pid: owner_pid}) do
    send(self(), {:connect_to_relay, relay_url, owner_pid})

    {:ok, %Socket{}}
  end

  @impl true
  def handle_cast({:subscribe, sub_id, encoded_filter}, state) do
    state = Sender.send_subscription_request(state, sub_id, encoded_filter)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:unsubscribe, subscription_id}, state) do
    state = Sender.send_close_message(state, subscription_id)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_event, event}, state) do
    json_request = SendRequest.event(event)

    state = Sender.send_text(state, json_request)

    {:noreply, state}
  end

  @impl true
  def handle_call({:all, limit}, _from, state) do
    {subscription_id, json} = Nostr.Client.Request.all(limit)

    send(self(), {:subscription_request, state, subscription_id, json})

    {:reply, subscription_id, state}
  end

  @impl true
  def handle_call(:ready?, _from, %Socket{websocket: nil} = state) do
    {:reply, false, state}
  end

  @impl true
  def handle_call(:ready?, _from, %Socket{websocket: _} = state) do
    {:reply, true, state}
  end

  @impl true
  def handle_call(:url, _from, %Socket{conn: conn} = state) do
    url = ~s(#{conn.private.scheme}://#{conn.host}:#{conn.port})

    {:reply, url, state}
  end

  @impl true
  def handle_call(
        command,
        _from,
        %Socket{url: url, owner_pid: owner_pid, websocket: nil} = state
      ) do
    command_name = elem(command, 0)
    reason = "Can't execute #{command_name} on #{url}, as websockets aren't enabled yet"

    Publisher.not_ready(owner_pid, url, reason)

    {:noreply, state}
  end

  @impl true
  def handle_call({:subscriptions}, _from, %{subscriptions: subscriptions} = state) do
    {:reply, subscriptions, state}
  end

  @impl true
  def handle_info({:connect_to_relay, relay_url, owner_pid}, state) do
    case Connector.connect(relay_url) do
      {:ok, conn, ref} ->
        Logger.info("Successful connection to #{relay_url}")
        Publisher.successful_connection(owner_pid, relay_url)

        {
          :noreply,
          %Socket{
            state
            | url: relay_url,
              conn: conn,
              request_ref: ref,
              owner_pid: owner_pid
          }
        }

      {:error, e} ->
        message = Exception.message(e)

        Publisher.unsuccessful_connection(owner_pid, relay_url, message)

        {:stop, {:shutdown, "error in Socket init: #{message}"}}
    end
  end

  @impl true
  def handle_info({:subscription_request, state, subscription_id, json}, state) do
    state = Sender.send_subscription_request(state, subscription_id, json)
    {:noreply, state}
  end

  #@impl true
  #def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
  #  {:noreply, state}
  #end

  @impl true
  def handle_info({:console, :ping, _url}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    MessageDispatcher.dispatch(message, state)
  end
end
