defmodule RTSP.RTP.Encoder.H26x do
  @moduledoc false

  import Bitwise

  alias ExRTP.Packet
  alias RTSP.RTP.Decoder.H264
  alias RTSP.RTP.Decoder.H265

  @max_rtp_seq_no (1 <<< 16) - 1

  def init(options, codec) do
    %{
      sequence_number: Keyword.get(options, :sequence_number, Enum.random(0..@max_rtp_seq_no)),
      max_payload_size: Keyword.get(options, :max_payload_size, 1460),
      payload_type: Keyword.get(options, :payload_type, 0),
      ssrc: Keyword.get(options, :ssrc, 0),
      codec: codec
    }
  end

  def handle_sample(au, timestamp, state) when is_list(au) do
    do_handle_sample(au, timestamp, state)
  end

  def handle_sample(au, timestamp, state) when is_binary(au) do
    do_handle_sample(MediaCodecs.H264.nalus(au), timestamp, state)
  end

  defp do_handle_sample(nalus, timestamp, state) do
    {packets, state, acc, _size} =
      Enum.reduce(nalus, {[], state, [], 0}, fn nalu, {packets, state, acc, size} ->
        cond do
          acc == [] and byte_size(nalu) > state.max_payload_size ->
            {new_packets, state} = encode(nalu, timestamp, state)
            {new_packets ++ packets, state, [], 0}

          acc != [] and byte_size(nalu) > state.max_payload_size ->
            {new_packet, state} = encode(acc, timestamp, state)
            {new_packets, state} = encode(nalu, timestamp, state)
            {new_packets ++ [new_packet | packets], state, [], 0}

          byte_size(nalu) + size < state.max_payload_size ->
            {packets, state, [nalu | acc], size + byte_size(nalu)}

          true ->
            {new_packet, state} = encode(acc, timestamp, state)
            {[new_packet | packets], state, [nalu], byte_size(nalu)}
        end
      end)

    case {acc, packets} do
      {[], [first | rest]} ->
        packets = Enum.reverse([%{first | marker: true} | rest])
        {packets, state}

      {acc, packets} ->
        {last_packet, state} = encode(acc, timestamp, state)
        packets = Enum.reverse([%{last_packet | marker: true} | packets])
        {packets, state}
    end
  end

  defp encode(nalu, timestamp, state) when is_binary(nalu) do
    mod =
      case state.codec do
        :h264 -> H264.FU
        :h265 -> H265.FU
      end

    nalu
    |> mod.serialize(state.max_payload_size)
    |> Enum.reduce({[], state}, fn fragment, {packets, state} ->
      packet = new_packet(fragment, timestamp, state)

      {[packet | packets],
       %{state | sequence_number: state.sequence_number + 1 &&& @max_rtp_seq_no}}
    end)
  end

  defp encode([nalu], timestamp, state) do
    {new_packet(nalu, timestamp, state),
     %{state | sequence_number: state.sequence_number + 1 &&& @max_rtp_seq_no}}
  end

  defp encode(nalus, timestamp, %{codec: :h264} = state) do
    <<f::1, nri::2, _type::5, _rest::binary>> = hd(nalus)

    packet =
      nalus
      |> H264.StapA.serialize(f, nri)
      |> new_packet(timestamp, state)

    {packet, %{state | sequence_number: state.sequence_number + 1 &&& @max_rtp_seq_no}}
  end

  defp encode(nalus, timestamp, %{codec: :h265} = state) do
    <<r::1, _type::6, layer_id::6, tid::3, _rest::binary>> = hd(nalus)

    packet =
      nalus
      |> H265.AP.serialize(r, layer_id, tid)
      |> new_packet(timestamp, state)

    {packet, %{state | sequence_number: state.sequence_number + 1 &&& @max_rtp_seq_no}}
  end

  defp new_packet(data, timestamp, state) do
    Packet.new(data,
      timestamp: timestamp,
      payload_type: state.payload_type,
      sequence_number: state.sequence_number,
      ssrc: state.ssrc
    )
  end
end
