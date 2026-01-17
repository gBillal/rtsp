defmodule RTSP.TCPReceiver do
  @moduledoc false

  use GenServer

  require Logger

  import RTSP.PacketSplitter
  import RTSP.Helper

  alias RTSP.RTP.OnvifReplayExtension
  alias RTSP.StreamHandler

  @active_mode 200

  defmodule State do
    @type t :: %__MODULE__{
            parent_pid: pid(),
            receiver: pid(),
            socket: :inet.socket(),
            rtsp_session: Membrane.RTSP.t(),
            tracks: [RTSP.track()],
            onvif_replay: boolean(),
            unprocessed_data: binary(),
            stream_handlers: map(),
            timeout: non_neg_integer()
          }

    @enforce_keys [:receiver, :parent_pid, :socket, :rtsp_session, :tracks]
    defstruct @enforce_keys ++
                [
                  onvif_replay: false,
                  unprocessed_data: <<>>,
                  stream_handlers: %{},
                  timeout: :timer.seconds(10)
                ]
  end

  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl true
  def init(options) do
    {:ok, struct!(State, options)}
  end

  @impl true
  def handle_info({:tcp, _port, data}, state) do
    {:noreply, do_handle_data(state, data)}
  end

  def handle_info({:tcp_passive, socket}, state) do
    :ok = :inet.setopts(socket, active: @active_mode)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp do_handle_data(receiver, data) do
    datetime = DateTime.utc_now()

    {{rtp_packets, _rtcp_packets}, unprocessed_data} =
      split_packets(receiver.unprocessed_data <> data, receiver.rtsp_session, {[], []})

    stream_handlers =
      rtp_packets
      |> Stream.map(&decode_rtp!/1)
      |> Stream.map(&decode_onvif_replay_extension/1)
      |> Enum.reduce(receiver.stream_handlers, fn %{ssrc: ssrc} = rtp_packet, handlers ->
        handlers = maybe_init_stream_handler(receiver, handlers, rtp_packet)

        datetime =
          case receiver do
            %{onvif_replay: true} ->
              rtp_packet.extensions && rtp_packet.extensions.timestamp

            _state ->
              datetime
          end

        {discontinuity?, sample, handler} =
          StreamHandler.handle_packet(handlers[ssrc], rtp_packet, datetime)

        if discontinuity?,
          do: send(receiver.receiver, {:rtsp, receiver.parent_pid, :discontinuity})

        if sample,
          do:
            send(
              receiver.receiver,
              {:rtsp, receiver.parent_pid, {handler.control_path, sample}}
            )

        Map.put(handlers, ssrc, handler)
      end)

    %{receiver | unprocessed_data: unprocessed_data, stream_handlers: stream_handlers}
  end

  defp decode_onvif_replay_extension(%ExRTP.Packet{extension_profile: 0xABAC} = packet) do
    extension = OnvifReplayExtension.decode(packet.extensions)
    %{packet | extensions: [extension]}
  end

  defp decode_onvif_replay_extension(packet), do: packet

  defp maybe_init_stream_handler(_state, handlers, %{ssrc: ssrc}) when is_map_key(handlers, ssrc),
    do: handlers

  defp maybe_init_stream_handler(state, handlers, packet) do
    track = Enum.find(state.tracks, &(&1.rtpmap.payload_type == packet.payload_type))

    encoding = track.rtpmap.encoding |> String.downcase() |> String.to_atom()
    {parser_mod, parser_state} = parser(encoding, track.fmtp)

    stream_handler = %StreamHandler{
      clock_rate: track.rtpmap.clock_rate,
      parser_mod: parser_mod,
      parser_state: parser_state,
      control_path: track.control_path
    }

    Map.put(handlers, packet.ssrc, stream_handler)
  end
end
