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
    * `{:rtsp, pid_or_name, {control_path, sample_or_samples}}` - Contains the media sample received from the stream.
      `control._path` is the RTSP control path for the track, and `sample` is the media sample data.
    * `{:rtsp, pid_or_name, :session_closed}` - Indicates that the RTSP session has been closed.

  A `sample` is a tuple in the format `{payload, rtp_timestamp, key_frame?, wallclock_timestamp}`:
    * `payload` - The media payload data (a whole access unit in case of `video`).
    * `rtp_timestamp` - The RTP timestamp of the sample as nano second starting from 0.
    * `key_frame?` - A boolean indicating whether the sample is a key frame (valid for `video` streams.)
    * `wallclock_timestamp` - The wall clock timestamp when the sample was received.

  >### TCP and UDP {: .info}
  > Currently only TCP transport is supported. UDP transport will be added in the future.
  """

  use GenServer

  require Logger

  alias RTSP.{ConnectionManager, State, TCPReceiver}

  @initial_recv_buffer 1_000_000

  @type session_opts :: [
          stream_uri: String.t(),
          allowed_media_types: [:video | :audio | :application],
          timeout: pos_integer() | :infinity,
          keep_alive_interval: pos_integer(),
          parent_pid: pid(),
          name: atom() | nil,
          onvif_replay: boolean(),
          start_date: DateTime.t() | nil,
          end_date: DateTime.t() | nil
        ]

  @typedoc """
  Represents a track in the RTSP session.

  Each track corresponds to a media stream and contains the following fields:
  * `control_path` - The RTSP control path for the track, can be used as an `id`.
  * `type` - The type of the media stream, which can be `:video`, `:audio`, or `:application`.
  * `fmtp` - The FMTP attribute for the track, which contains format-specific parameters.
  * `rtpmap` - The RTP mapping attribute for the track, which contains information about the payload type and encoding.
  """
  @type track :: %{
          control_path: String.t(),
          type: :video | :audio | :application,
          fmtp: ExSDP.Attribute.FMTP.t() | nil,
          rtpmap: ExSDP.Attribute.RTPMapping.t() | nil
        }

  @doc """
  Starts a new RTSP client session.

  The following options can be provided:

  * `:stream_uri` - The RTSP stream URI to connect to (required).
  * `:allowed_media_types` - A list of allowed media types, defaults to: `[:video, :audio]`.
  * `:timeout` - The timeout for RTSP operations (default: `5 seconds`).
  * `:keep_alive_interval` - The interval for sending keep-alive messages (default: `30 seconds`).
  * `:parent_pid` - The parent process that will receive messages, defaults to the calling process.
  * `:name` - The name of the GenServer process, if provided it'll be used as the first element in the sent messages.

  ### Onvif Replay
  To decode `onvif replay` extension packets, the following options can be provided

  * `:onvif_replay` - Whether to enable ONVIF replay extension (default: `false`).
  * `:start_date` - The start date for the session.
  * `:end_date` - The end date for the session.
  """
  @spec start_link(session_opts()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :parent_pid, self())
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Connects the rtsp server./home/ghilas/p/Evercam/ex_nvr/rtsp/lib/rtsp/source.ex

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
    state = %State{
      stream_uri: opts[:stream_uri],
      transport: :tcp,
      allowed_media_types: opts[:allowed_media_types] || [:video, :audio],
      timeout: opts[:timeout] || :timer.seconds(5),
      keep_alive_interval: opts[:keep_alive_interval] || :timer.seconds(30),
      onvif_replay: opts[:onvif_replay] || false,
      start_date: opts[:start_date],
      end_date: opts[:end_date],
      parent_pid: opts[:parent_pid],
      name: opts[:name] || self()
    }

    # Don't exit if rtsp session crashed or stopped
    Process.flag(:trap_exit, true)

    {:ok, state}
  end

  @impl true
  def handle_call(:connect, _from, %{state: state}) when state != :init do
    raise "Session state is in #{state}, cannot connect again"
  end

  @impl true
  def handle_call(:connect, _from, state) do
    case RTSP.ConnectionManager.establish_connection(state) do
      {:ok, %{tracks: tracks} = new_state} ->
        {:tcp, socket} = List.first(tracks).transport
        tracks = Enum.map(tracks, &Map.delete(&1, :transport))
        {:reply, {:ok, tracks}, %{new_state | socket: socket, state: :connected}}

      {:error, reason} ->
        {:reply, {:error, reason}, ConnectionManager.clean(state)}
    end
  end

  @impl true
  def handle_call(:play, _from, %{state: :connected} = state) do
    case RTSP.ConnectionManager.play(state) do
      {:ok, new_state} ->
        :ok = :inet.setopts(state.socket, buffer: @initial_recv_buffer, active: false)
        :ok = Membrane.RTSP.transfer_socket_control(new_state.rtsp_session, self())

        pid =
          spawn(fn ->
            receiver =
              TCPReceiver.new(
                parent_pid: new_state.name,
                receiver_pid: new_state.parent_pid,
                socket: new_state.socket,
                rtsp_session: new_state.rtsp_session,
                tracks: new_state.tracks,
                onvif_replay: new_state.onvif_replay
              )

            TCPReceiver.start(receiver)
          end)

        Process.monitor(pid)

        {:reply, :ok, ConnectionManager.check_recbuf(new_state)}

      {:error, reason} ->
        {:reply, {:error, reason}, ConnectionManager.clean(state)}
    end
  end

  @impl true
  def handle_call(:play, _from, state) do
    raise "Session is not on a connected state, current state is #{state.state}"
  end

  @impl true
  def handle_call(:stop, _from, state) do
    {:reply, :ok, ConnectionManager.clean(state)}
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
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    send(state.parent_pid, {:rtsp, state.name, :session_closed})
    {:noreply, ConnectionManager.clean(state)}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
