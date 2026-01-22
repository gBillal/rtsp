defmodule RTSP.RTPReceiver.UDP do
  @moduledoc """
  Module processing rtp/rtcp data coming from UDP sockets.

  This module handles:
  - RTP packet parsing
  - Packet reordering
  - Stream handling (decoding RTP payloads into samples)
  """

  alias RTSP.RTP.PacketReorderer

  import RTSP.Helper

  @opaque t :: %__MODULE__{
            socket: :inet.socket(),
            rtcp_socket: :inet.socket(),
            track: RTSP.track(),
            packet_reorderer: PacketReorderer.t(),
            stream_handler: RTSP.StreamHandler.t() | nil
          }

  defstruct [:socket, :rtcp_socket, :track, :packet_reorderer, :stream_handler]

  @doc """
  Creates a new UDP RTP receiver.
  """
  @spec new(:inet.socket(), :inet.socket(), RTSP.track()) :: t()
  @spec new(:inet.socket(), :inet.socket(), RTSP.track(), keyword()) :: t()
  def new(socket, rtcp_socket, track, opts \\ []) do
    encoding = track.rtpmap.encoding |> String.downcase() |> String.to_atom()
    {parser_mod, parser_state} = parser(encoding, track.fmtp)

    stream_handler = %RTSP.StreamHandler{
      clock_rate: track.rtpmap.clock_rate,
      parser_mod: parser_mod,
      parser_state: parser_state,
      control_path: track.control_path
    }

    %__MODULE__{
      socket: socket,
      rtcp_socket: rtcp_socket,
      track: track,
      packet_reorderer: PacketReorderer.new(opts[:reorder_queue_size] || 64),
      stream_handler: stream_handler
    }
  end

  @doc """
  Processes an incoming RTP packet.
  """
  @spec process(binary(), t()) ::
          {list(
             {:discontinuity, RTSP.control_path()}
             | {RTSP.control_path(), RTSP.sample() | [RTSP.sample()]}
           ), t()}
  def process(packet, state) do
    datetime = System.os_time(:millisecond)

    {packets, packet_reorderer} =
      packet
      |> decode_rtp!()
      |> PacketReorderer.process(state.packet_reorderer)

    {events, handler} =
      Enum.reduce(packets, {[], state.stream_handler}, fn rtp_packet, {acc, handler} ->
        case RTSP.StreamHandler.handle_packet(handler, rtp_packet, datetime) do
          {false, nil, handler} ->
            {acc, handler}

          {false, sample, handler} ->
            {[{handler.control_path, sample} | acc], handler}

          {true, nil, handler} ->
            {[{:discontinuity, handler.control_path} | acc], handler}

          {_, sample, handler} ->
            {[{handler.control_path, sample}, {:discontinuity, handler.control_path} | acc],
             handler}
        end
      end)

    state = %{state | stream_handler: handler, packet_reorderer: packet_reorderer}
    {Enum.reverse(events), state}
  end

  @doc """
  Closes the UDP RTP receiver sockets.
  """
  @spec close(t()) :: :ok
  def close(state) do
    :gen_udp.close(state.socket)
    :gen_udp.close(state.rtcp_socket)
  end
end
