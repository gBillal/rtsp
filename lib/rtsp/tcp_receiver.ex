defmodule RTSP.TCPReceiver do
  @moduledoc false

  import RTSP.PacketSplitter

  require Logger

  alias RTSP.RTP.{Decoder, OnvifReplayExtension}
  alias RTSP.StreamHandler

  @type t :: %__MODULE__{
          parent_pid: pid(),
          receiver_pid: pid(),
          socket: :inet.socket(),
          rtsp_session: Membrane.RTSP.t(),
          tracks: [RTSP.track()],
          onvif_replay: boolean(),
          unprocessed_data: binary(),
          stream_handlers: map(),
          timeout: non_neg_integer()
        }

  @enforce_keys [:receiver_pid, :parent_pid, :socket, :rtsp_session, :tracks]
  defstruct @enforce_keys ++
              [
                onvif_replay: false,
                unprocessed_data: <<>>,
                stream_handlers: %{},
                timeout: :timer.seconds(10)
              ]

  @spec new(keyword()) :: t()
  def new(options), do: struct!(__MODULE__, options)

  def start(receiver) do
    case :gen_tcp.recv(receiver.socket, 0, receiver.timeout) do
      {:ok, data} ->
        receiver
        |> do_handle_data(data)
        |> start()

      {:error, reason} ->
        Logger.error("Error receiving data: #{inspect(reason)}")
        :ok
    end
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
            %__MODULE__{onvif_replay: true} ->
              rtp_packet.extensions && rtp_packet.extensions.timestamp

            _state ->
              datetime
          end

        {discontinuity?, sample, handler} =
          StreamHandler.handle_packet(handlers[ssrc], rtp_packet, datetime)

        if discontinuity?,
          do: send(receiver.receiver_pid, {:rtsp, receiver.parent_pid, :discontinuity})

        if sample,
          do:
            send(
              receiver.receiver_pid,
              {:rtsp, receiver.parent_pid, {handler.control_path, sample}}
            )

        Map.put(handlers, ssrc, handler)
      end)

    %{receiver | unprocessed_data: unprocessed_data, stream_handlers: stream_handlers}
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

  defp parser(:H264, fmtp) do
    sps = fmtp.sprop_parameter_sets && fmtp.sprop_parameter_sets.sps
    pps = fmtp.sprop_parameter_sets && fmtp.sprop_parameter_sets.pps

    {Decoder.H264, Decoder.H264.init(sps: sps, pps: pps)}
  end

  defp parser(:H265, fmtp) do
    parser_state =
      Decoder.H265.init(
        vpss: List.wrap(fmtp && fmtp.sprop_vps) |> Enum.map(&clean_parameter_set/1),
        spss: List.wrap(fmtp && fmtp.sprop_sps) |> Enum.map(&clean_parameter_set/1),
        ppss: List.wrap(fmtp && fmtp.sprop_pps) |> Enum.map(&clean_parameter_set/1)
      )

    {Decoder.H265, parser_state}
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
