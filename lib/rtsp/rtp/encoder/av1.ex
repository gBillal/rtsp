defmodule RTSP.RTP.Encoder.AV1 do
  @moduledoc """
  Payload AV1 OBUs into RTP packets.

  This module accept as input a list of OBUs or a binary payload containing AV1 OBUs. It
  does not support extension headers in the sense that an OBU that have different temporal or scalable layer
  should start a new RTP packet.
  """

  @behaviour RTSP.RTP.Encoder

  import Bitwise

  alias MediaCodecs.AV1

  @max_payload_size 1460
  @max_rtp_seq_no (2 <<< 16) - 1

  @impl true
  def init(options) do
    %{
      max_payload_size: Keyword.get(options, :max_payload_size, @max_payload_size),
      sequence_number: Keyword.get(options, :sequence_number, Enum.random(0..@max_rtp_seq_no)),
      ssrc: Keyword.get(options, :ssrc, 0),
      payload_type: Keyword.get(options, :payload_type, 0),
      # store Z, Y and payload
      packets: [{0, 0, []}],
      packet_size: 0,
      length: 1
    }
  end

  @impl true
  def handle_sample(obus, timestamp, state) when is_list(obus) do
    state =
      obus
      |> Stream.map(&AV1.OBU.clear_size_flag/1)
      |> Enum.reduce(state, &push_obu/2)

    seq_num = state.sequence_number + state.length - 1
    keyframe = Enum.any?(obus, &AV1.OBU.keyframe?/1)

    {packets, _seq_num} =
      Enum.reduce(state.packets, {[], seq_num}, fn {z, y, payload}, {packets, seq} ->
        # N flag is set if keyframe and first packet
        n = (seq == state.sequence_number && keyframe && 1) || 0
        payload = IO.iodata_to_binary([<<z::1, y::1, 0::2, n::1, 0::3>> | Enum.reverse(payload)])

        packet =
          ExRTP.Packet.new(payload,
            timestamp: timestamp,
            sequence_number: seq &&& @max_rtp_seq_no,
            payload_type: state.payload_type,
            ssrc: state.ssrc,
            marker: seq == seq_num
          )

        {[packet | packets], seq - 1}
      end)

    {packets,
     %{
       state
       | sequence_number: seq_num + 1 &&& @max_rtp_seq_no,
         packet_size: 0,
         packets: [{0, 0, []}],
         length: 1
     }}
  end

  def handle_sample(payload, timestamp, state) do
    handle_sample(AV1.obus(payload), timestamp, state)
  end

  defp push_obu(obu, state) do
    [{z, y, packet} | rest] = state.packets

    if state.packet_size + byte_size(obu) >= state.max_payload_size do
      offset = state.max_payload_size - state.packet_size
      <<to_add::binary-size(offset), remaining::binary>> = obu
      size = MediaCodecs.Helper.leb128_encode(byte_size(to_add))

      state = %{
        state
        | packets: [{1, 0, []}, {z, 1, [to_add, size | packet]} | rest],
          packet_size: 0,
          length: state.length + 1
      }

      push_obu(remaining, state)
    else
      size = MediaCodecs.Helper.leb128_encode(byte_size(obu))

      %{
        state
        | packets: [{z, y, [obu, size | packet]} | rest],
          packet_size: state.packet_size + byte_size(obu) + byte_size(size)
      }
    end
  end
end
