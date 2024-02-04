defmodule Nostr.Relay.Socket.Server do
  @moduledoc """
  The GenServer implementation. Its state is the websocket state, as well as a list of subscriptions currently active on this relay.
  """

  use GenServer

  require Logger

  alias Nostr.Relay.Socket
  alias Nostr.Relay.Socket.{Connector, Response, Publisher, Sender}
  alias Nostr.Client.Request
  alias Mint.{HTTP, Types, WebSocket}

  @impl true
  def init(%{relay_url: relay_url, owner_pid: owner_pid}) do
    send(self(), {:connect_to_relay, relay_url, owner_pid})

    {:ok, %Socket{}}
  end

  @impl true
  def handle_cast({:subscribe, sub_id, encoded_filter}, state) do
    state = send_subscription_request(state, sub_id, encoded_filter)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:unsubscribe, subscription_id}, state) do
    state = send_close_message(state, subscription_id)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_event, event}, state) do
    state = case send_frame(state, {:text, event}) do
      {:ok, state} ->
        state

      {:error, state, reason} ->
        Logger.error(reason)
        state
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:all, limit}, _from, state) do
    {subscription_id, json} = Request.all(limit)

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
    url = "#{conn.private.scheme}://#{conn.host}:#{conn.port}"

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
    case connect(relay_url) do
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
    state = send_subscription_request(state, subscription_id, json)
    {:noreply, state}
  end

  # @impl true
  # def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
  #  {:noreply, state}
  # end

  @impl true
  def handle_info({:console, :ping, _url}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state), do: Response.dispatch(message, state)

  @spec send_pong(map(), String.t()) :: {:ok, map()} | {:error, map(), any()}
  def send_pong(state, data) do
    send_frame(state, {:pong, data})
  end

  @spec send_subscription_request(map(), atom(), String.t()) :: map()
  def send_subscription_request(state, sub_id, json) do
    case send_frame(state, {:text, json}) do
      {:ok, state} ->
        add_subscription(state, sub_id)

      {:error, state, reason} ->
        Logger.error(reason)
        state
    end
  end

  @spec send_close_message(map(), pid()) :: map()
  def send_close_message(state, subscription_id) do
    {:ok, json_request} = Jason.encode(["CLOSE", subscription_id])
    # wait for "CLOSED" ack message
    case send_frame(state, {:text, json_request}) do
      {:ok, state} ->
        remove_subscription(state, subscription_id)

      {:error, state, reason} ->
        Logger.error(reason)
        state
    end
  end

  @spec close(map()) :: HTTP.t()
  def close(%{conn: conn} = state) do
    _ = send_frame(state, :close)

    {:ok, conn} = HTTP.close(conn)

    conn
  end

  # @spec send_subscription_to_websocket(map(), atom(), String.t(), pid()) ::
  #        {:ok, map()} | {:error, map(), any()}
  # defp send_subscription_to_websocket(state, atom_subscription_id, json) do
  #  case send_frame(state, {:text, json}) do
  #    {:ok, state} ->
  #      {
  #        :ok,
  #        add_subscription(state, atom_subscription_id)
  #      }
  #
  #    {:error, state, message} ->
  #      {:error, state, message}
  #  end
  # end

  @spec send_frame(map(), any()) :: {:ok, map()} | {:error, map(), any()}
  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- WebSocket.encode(state.websocket, frame),
         state = put_in(state.websocket, websocket),
         {:ok, conn} <- WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, put_in(state.conn, conn)}
    else
      {:error, %WebSocket{} = websocket, reason} ->
        {:error, put_in(state.websocket, websocket), reason}

      {:error, conn, reason} ->
        {:error, put_in(state.conn, conn), reason}
    end
  end

  defp add_subscription(%{subscriptions: subs} = state, atom_subscription_id) do
    Logger.info("Adding subscription to state")
    %{state | subscriptions: [ atom_subscription_id | subs ]}
  end

  defp remove_subscription(%{subscriptions: subs} = state, atom_subscription_id) do
    new_subscriptions = List.delete(subs, atom_subscription_id)

    %{state | subscriptions: new_subscriptions}
  end

  @spec connect(String.t()) :: {:ok, HTTP.t(), Types.request_ref()} | {:error, Types.error()}
  def connect(relay_url) do
    uri = URI.parse(relay_url)

    http_scheme =
      case uri.scheme do
        "ws" -> :http
        "wss" -> :https
      end

    ws_scheme =
      case uri.scheme do
        "ws" -> :ws
        "wss" -> :wss
      end

    path = uri.path || "/"

    with {:ok, conn} <- HTTP.connect(http_scheme, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- WebSocket.upgrade(ws_scheme, conn, path, []) do
      {:ok, conn, ref}
    else
      {:error, %Mint.TransportError{reason: :nxdomain}} ->
        message = "domain doesn't exist"
        {:error, message}

      {:error, reason} ->
        {:error, reason}

      {:error, _conn, reason} ->
        {:error, reason}
    end
  end
end
