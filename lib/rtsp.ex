defmodule RTSP do
  @moduledoc """
  Simplify connecting to RTSP servers.

  ### Usage
  To start an RTSP session, you can use the `start_link/1` function with the required options:

      {:ok, session} = RTSP.start_link(stream_uri: "rtsp://localhost:554/stream", allowed_media_types: [:video])
      {:ok, tracks} = RTSP.connect(session)
      :ok = RTSP.play(session)

  The calling process will receive messages with the received media samples.

  ### Message Types

  The calling process will receive messages in the following format:

    * `{:rtsp, pid_or_name, :discontinuity}` - Indicates a discontinuity in the stream.
    * `{:rtsp, pid_or_name, {control_path, sample_or_samples}}` - Contains the media sample(s) received from the stream.
      `control_path` is the RTSP control path for the track, and `sample` is the media sample data.
    * `{:rtsp, pid_or_name, :session_closed}` - Indicates that the RTSP session has been closed.

  A sample format is described in the `t:sample/0` type.
  """

  use GenServer

  require Logger

  alias RTSP.{ConnectionManager, State, TCPReceiver, UDPReceiver}

  @initial_recv_buffer 1_000_000

  @onvif_replay_options [
    start_date: [
      doc: "The start date for the onvif replay session.",
      type: {:struct, DateTime},
      required: true
    ],
    end_date: [
      doc: "The end date for the onvif replay session.",
      type: {:struct, DateTime},
      default: nil
    ]
  ]

  @session_options [
    stream_uri: [
      doc: "The RTSP stream URI to connect to.",
      type: :string,
      required: true
    ],
    allowed_media_types: [
      doc: "The type of media streams to request from the rtsp server.",
      type: {:list, {:in, [:application, :audio, :video]}},
      default: [:audio, :video]
    ],
    transport: [
      doc: """
      The transport protocol to use for the RTSP session.

      This can be either:
      * `:tcp` - for TCP transport.
      * `{:udp, min_port, max_port}` - for UDP transport, where `min_port` and `max_port` are the port range for RTP and RTCP streams.
      """,
      type: {:custom, __MODULE__, :check_transport, []},
      default: :tcp
    ],
    timeout: [
      doc: "The timeout for RTSP operations.",
      type: :timeout,
      default: :timer.seconds(5)
    ],
    reorder_queue_size: [
      doc: """
      Set number of packets to buffer for handling of reordered packets.

      Due to the implementation, this size should be an exponent of 2.
      """,
      type: :pos_integer,
      default: 64
    ],
    receiver: [
      doc: "The process that will receive media streams messages.",
      type: :pid
    ],
    onvif_replay: [
      doc: "The stream uri is an onvif replay.",
      keys: @onvif_replay_options
    ]
  ]

  @type control_path :: String.t()

  @typedoc """
  Represents a track in the RTSP session.

  Each track corresponds to a media stream and contains the following fields:
  * `control_path` - The RTSP control path for the track, can be used as an `id`.
  * `type` - The type of the media stream, which can be `:video`, `:audio`, or `:application`.
  * `fmtp` - The FMTP attribute for the track, which contains format-specific parameters.
  * `rtpmap` - The RTP mapping attribute for the track, which contains information about the payload type and encoding.
  """
  @type track :: %{
          control_path: control_path(),
          type: :video | :audio | :application,
          fmtp: ExSDP.Attribute.FMTP.t() | nil,
          rtpmap: ExSDP.Attribute.RTPMapping.t() | nil
        }

  @typedoc """
  Represents a media sample received from the RTSP stream.

  The sample is a tuple containing:
  * `payload` - The media payload data (a whole access unit in case of `video`).
  * `pts` - The RTP timestamp of the sample in the advertised clock rate starting from 0.
  * `keyframe?` - A boolean indicating whether the sample is a key frame (always `true` for non video codecs).
  * `timestamp` - The wall clock timestamp when the sample was received in milliseconds.
  """
  @type sample ::
          {iodata(), pts :: non_neg_integer(), keyframe? :: boolean(),
           timestamp :: non_neg_integer()}

  @doc """
  Starts a new RTSP client session.

  The following options can be provided:\n#{NimbleOptions.docs(@session_options, nest_level: 1)}
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :receiver, self())
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Connects the rtsp server.

  It returns the set up tracks in case of success.
  """
  @spec connect(pid()) :: {:ok, [track()]} | {:error, reason :: any()}
  @spec connect(pid(), timeout()) :: {:ok, [track()]} | {:error, reason :: any()}
  def connect(pid, timeout \\ 5000) do
    GenServer.call(pid, :connect, timeout)
  end

  @doc """
  Sends a play request and starts receiving media streams.
  """
  @spec play(pid(), timeout()) :: :ok | {:error, reason :: any()}
  def play(pid, timeout \\ 5000) do
    GenServer.call(pid, :play, timeout)
  end

  @doc """
  Closes the RTSP session and stops receiving media streams.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @impl true
  def init(opts) do
    opts = NimbleOptions.validate!(opts, @session_options)
    state = struct!(State, opts)

    # Don't exit if rtsp session crashed or stopped
    Process.flag(:trap_exit, true)

    {:ok, %{state | name: self()}}
  end

  @impl true
  def handle_call(:connect, _from, %{state: status} = state) when status != :init do
    {:reply, {:error, :invalid_state}, state}
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case RTSP.ConnectionManager.establish_connection(state) do
      {:ok, %{tracks: tracks} = new_state} ->
        new_state =
          case new_state.transport do
            :tcp ->
              {:tcp, socket} = List.first(tracks).transport
              %{new_state | socket: socket}

            _udp ->
              new_state
          end

        tracks = Enum.map(tracks, &Map.delete(&1, :transport))
        {:reply, {:ok, tracks}, %{new_state | state: :connected}}

      {:error, reason} ->
        {:reply, {:error, reason}, ConnectionManager.clean(state)}
    end
  end

  @impl true
  def handle_call(:play, _from, %{state: :connected} = state) do
    case RTSP.ConnectionManager.play(state) do
      {:ok, new_state} -> {:reply, :ok, start_receivers(new_state)}
      {:error, reason} -> {:reply, {:error, reason}, ConnectionManager.clean(state)}
    end
  end

  @impl true
  def handle_call(:play, _from, state), do: {:reply, {:error, :invalid_state}, state}

  @impl true
  def handle_call(:stop, _from, state) do
    state = ConnectionManager.clean(state)
    Enum.each(state.udp_receivers, &UDPReceiver.stop/1)
    notify_closed_session(state)
    {:reply, :ok, %{state | udp_receivers: [], tcp_receiver: nil}}
  end

  @impl true
  def handle_info(:keep_alive, state) do
    {:noreply, ConnectionManager.keep_alive(state)}
  end

  @impl true
  def handle_info(:check_recbuf, state) do
    {:noreply, ConnectionManager.check_recbuf(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      cond do
        pid == state.tcp_receiver ->
          notify_closed_session(state)
          ConnectionManager.clean(%{state | tcp_receiver: nil})

        pid in state.udp_receivers ->
          case List.delete(state.udp_receivers, pid) do
            [] ->
              notify_closed_session(state)
              ConnectionManager.clean(%{state | udp_receivers: []})

            receivers ->
              %{state | udp_receivers: receivers}
          end

        true ->
          ConnectionManager.clean(state)
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, ConnectionManager.clean(state)}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp start_receivers(%{transport: :tcp} = state) do
    options = [
      parent_pid: state.name,
      receiver: state.receiver,
      socket: state.socket,
      rtsp_session: state.rtsp_session,
      tracks: state.tracks,
      onvif_replay: state.onvif_replay != []
    ]

    {:ok, pid} = TCPReceiver.start(options)

    :ok = :inet.setopts(state.socket, buffer: @initial_recv_buffer, active: 100)
    :ok = Membrane.RTSP.transfer_socket_control(state.rtsp_session, pid)

    Process.monitor(pid)
    %{state | tcp_receiver: pid}
  end

  defp start_receivers(%{name: parent_pid, receiver: receiver} = state) do
    server_ip = ConnectionManager.get_server_ip(state)

    Enum.map(state.tracks, fn track ->
      opts = [
        parent_pid: parent_pid,
        receiver: receiver,
        track: track,
        reorder_queue_size: state.reorder_queue_size,
        server_ip: server_ip
      ]

      {:ok, pid} = UDPReceiver.start(opts)

      Process.monitor(pid)
      pid
    end)
    |> then(&%{state | udp_receivers: &1})
  end

  defp notify_closed_session(state) do
    send(state.receiver, {:rtsp, state.name, :session_closed})
  end

  @doc false
  def check_transport(:tcp), do: {:ok, :tcp}

  def check_transport({:udp, min_port, max_port} = value)
      when is_integer(min_port) and is_integer(max_port) and min_port < max_port,
      do: {:ok, value}

  def check_transport(value), do: {:error, "#{inspect(value)}"}
end
