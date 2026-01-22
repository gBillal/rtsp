defmodule RTSP.Server.ClientSession do
  @moduledoc """
  Module handling a RTSP client session once connected to a server.
  """

  use GenServer

  alias RTSP.RTPReceiver

  @doc """
  Starts a client session.

  This should be started automatically by the RTSP server when a new client connects.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def handle_announce(pid, request) do
    GenServer.call(pid, {:announce, request})
  end

  @doc false
  def start_recording(pid, configured_media_context) do
    GenServer.call(pid, {:start_recording, configured_media_context})
  end

  @doc false
  def tracks(pid) do
    GenServer.call(pid, :tracks)
  end

  @doc """
  Closes the client session.
  """
  @spec close(GenServer.server()) :: :ok
  def close(server) do
    GenServer.call(server, :close)
  end

  @impl true
  def init(options) do
    handler = options[:handler]
    handler_state = handler.init(options[:handler_config])
    {:ok, %{handler: handler, handler_state: handler_state, tracks: nil, receivers: %{}}}
  end

  @impl true
  def handle_call({:announce, request}, _from, state) do
    path = URI.parse(request.path).path

    tracks =
      request
      |> RTSP.Helper.get_tracks()
      |> Enum.map(&Map.drop(&1, [:transport, :server_port]))

    case state.handler.handle_record(path, tracks, state.handler_state) do
      {:ok, handler_state} ->
        {:reply, :ok, %{state | handler_state: handler_state, tracks: tracks}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start_recording, configured_media_context}, _from, state) do
    receivers =
      Map.new(configured_media_context, fn {key, ctx} ->
        track = Enum.find(state.tracks, &String.ends_with?(key, &1.control_path))
        {ctx.rtp_socket, RTPReceiver.UDP.new(ctx.rtp_socket, ctx.rtcp_socket, track)}
      end)

    {:reply, :ok, %{state | receivers: receivers}}
  end

  def handle_call(:tracks, _from, state) do
    {:reply, state.tracks, state}
  end

  def handle_call(:close, _from, state) do
    state.handler.handle_closed_connection(state.handler_state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, data}, state) do
    case Map.get(state.receivers, socket) do
      nil ->
        # rtcp packet, ignore
        {:noreply, state}

      receiver ->
        {events, receiver} = RTPReceiver.UDP.process(data, receiver)

        handler_state =
          Enum.reduce(events, state.handler_state, fn
            {:discontinuity, control_path}, handler_state ->
              state.handler.handle_discontinuity(control_path, handler_state)

            {control_path, sample}, handler_state ->
              state.handler.handle_media(control_path, sample, handler_state)
          end)

        state = %{
          state
          | handler_state: handler_state,
            receivers: Map.put(state.receivers, socket, receiver)
        }

        {:noreply, state}
    end
  end

  def handle_info({:udp_error, _socket, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
