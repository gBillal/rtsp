defmodule RTSP.RTP.Encoder.H264 do
  @moduledoc """
  Payload H264 access units into RTP packets.
  """

  @behaviour RTSP.RTP.Encoder

  import Bitwise

  alias ExRTP.Packet
  alias RTSP.RTP.Decoder.H264.{FU, StapA}

  @nalu_prefixes [<<1::24>>, <<1::32>>]
  @max_rtp_seq_no (1 <<< 16) - 1

  @impl true
  def init(options) do
    %{
      sequence_number: Keyword.get(options, :sequence_number, Enum.random(0..@max_rtp_seq_no)),
      max_payload_size: Keyword.get(options, :max_payload_size, 1460),
      payload_type: Keyword.get(options, :payload_type, 0)
    }
  end

  @impl true
  def handle_sample(au, timestamp, state) do
    {packets, state, acc, _size} =
      au
      |> :binary.split(@nalu_prefixes, [:global, :trim_all])
      |> Enum.reduce({[], state, [], 0}, fn nalu, {packets, state, acc, size} ->
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
    nalu
    |> FU.serialize(state.max_payload_size)
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

  defp encode(nalus, timestamp, state) do
    <<f::1, nri::2, _type::5, _rest::binary>> = hd(nalus)

    packet =
      nalus
      |> StapA.serialize(f, nri)
      |> new_packet(timestamp, state)

    {packet, %{state | sequence_number: state.sequence_number + 1 &&& @max_rtp_seq_no}}
  end

  defp new_packet(data, timestamp, state) do
    Packet.new(data,
      timestamp: timestamp,
      payload_type: state.payload_type,
      sequence_number: state.sequence_number
    )
  end
end
