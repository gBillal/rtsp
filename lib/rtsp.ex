defmodule RTSP do
  @moduledoc """
  RTSP client
  """

  use GenServer

  require Logger

  import __MODULE__.PacketSplitter

  alias RTSP.ConnectionManager
  alias RTSP.RTP.OnvifReplayExtension
  alias RTSP.State
  alias RTSP.StreamHandler

  @initial_recv_buffer 1_000_000

  @type track :: %{
          control_path: String.t(),
          type: :video | :audio | :application,
          fmtp: ExSDP.Attribute.FMTP.t() | nil,
          rtpmap: ExSDP.Attribute.RTPMapping.t() | nil
        }

  @doc """
  Starts a new RTSP client session.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :parent_pid, self())
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Connects the rtsp server./home/ghilas/p/Evercam/ex_nvr/rtsp/lib/rtsp/source.ex

  It returns the set up tracks in case of success.
  """
  @spec connect(pid()) :: {:ok, [track()]} | {:error, reason :: any()}
  def connect(pid) do
    GenServer.call(pid, :connect)
  end

  @doc """
  Sends a play request and starts receiving media streams.
  """
  @spec play(pid()) :: :ok | {:error, reason :: any()}
  def play(pid) do
    GenServer.call(pid, :play)
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
      start_date: opts[:start_date] || DateTime.utc_now(),
      end_date: opts[:end_date],
      parent_pid: opts[:parent_pid]
    }

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
        self = self()

        pid =
          spawn(fn ->
            state = %{
              unprocessed_data: <<>>,
              stream_handlers: %{},
              pid: self,
              parent_pid: new_state.parent_pid,
              socket: new_state.socket,
              timeout: new_state.timeout,
              rtsp_session: new_state.rtsp_session,
              tracks: new_state.tracks,
              onvif_replay: new_state.onvif_replay
            }

            receive_data(state)
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
  def handle_info(:keep_alive, state) do
    {:noreply, ConnectionManager.keep_alive(state)}
  end

  @impl true
  def handle_info(:check_recbuf, state) do
    {:noreply, ConnectionManager.check_recbuf(state)}
  end

  defp receive_data(state) do
    case :gen_tcp.recv(state.socket, 0, state.timeout) do
      {:ok, data} ->
        state
        |> do_handle_data(data)
        |> receive_data()

      {:error, reason} ->
        Logger.error("Error receiving data: #{inspect(reason)}")
        :ok
    end
  end

  defp do_handle_data(state, data) do
    datetime = DateTime.utc_now()

    {rtp_packets, _rtcp_packets, unprocessed_data} =
      split_packets(state.unprocessed_data <> data, state.rtsp_session, {[], []})

    stream_handlers =
      rtp_packets
      |> Stream.map(&decode_rtp!/1)
      |> Stream.map(&decode_onvif_replay_extension/1)
      |> Enum.reduce(state.stream_handlers, fn %{ssrc: ssrc} = rtp_packet, handlers ->
        handlers = maybe_init_stream_handler(state, handlers, rtp_packet)

        datetime =
          case state do
            %State{onvif_replay: true} ->
              rtp_packet.extensions && rtp_packet.extensions.timestamp

            _state ->
              datetime
          end

        {discontinuity?, sample, handler} =
          StreamHandler.handle_packet(handlers[ssrc], rtp_packet, datetime)

        if discontinuity?, do: send(state.parent_pid, {state.pid, :discontinuity})
        if sample, do: send(state.parent_pid, {state.pid, handler.control_path, sample})

        Map.put(handlers, ssrc, handler)
      end)

    %{state | unprocessed_data: unprocessed_data, stream_handlers: stream_handlers}
  end

  defp decode_rtp!(packet) do
    case ExRTP.Packet.decode(packet) do
      {:ok, packet} ->
        packet

      _error ->
        raise """
        invalid rtp packet
        #{inspect(packet, limit: :infinity)}
        """
    end
  end

  defp decode_onvif_replay_extension(%ExRTP.Packet{extension_profile: 0xABAC} = packet) do
    extension = OnvifReplayExtension.decode(packet.extensions)
    %{packet | extensions: extension}
  end

  defp decode_onvif_replay_extension(packet), do: packet

  defp maybe_init_stream_handler(_state, handlers, %{ssrc: ssrc}) when is_map_key(handlers, ssrc),
    do: handlers

  defp maybe_init_stream_handler(state, handlers, packet) do
    track = Enum.find(state.tracks, &(&1.rtpmap.payload_type == packet.payload_type))

    encoding = String.to_atom(track.rtpmap.encoding)
    {parser_mod, parser_state} = parser(encoding, track.fmtp)

    stream_handler = %StreamHandler{
      clock_rate: track.rtpmap.clock_rate,
      parser_mod: parser_mod,
      parser_state: parser_state,
      control_path: track.control_path
    }

    Map.put(handlers, packet.ssrc, stream_handler)
  end

  defp parser(:H265, fmtp) do
    parser_state =
      RTSP.RTP.H265.init(
        vpss: List.wrap(fmtp && fmtp.sprop_vps) |> Enum.map(&clean_parameter_set/1),
        spss: List.wrap(fmtp && fmtp.sprop_sps) |> Enum.map(&clean_parameter_set/1),
        ppss: List.wrap(fmtp && fmtp.sprop_pps) |> Enum.map(&clean_parameter_set/1)
      )

    {RTSP.RTP.H265, parser_state}
  end

  # An issue with one of Milesight camera where the parameter sets have
  # <<0, 0, 0, 1>> at the end
  defp clean_parameter_set(ps) do
    case :binary.part(ps, byte_size(ps), -4) do
      <<0, 0, 0, 1>> -> :binary.part(ps, 0, byte_size(ps) - 4)
      _other -> ps
    end
  end
end
