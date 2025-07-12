defmodule RTSP.RTP.PacketReorderer do
  @moduledoc """
  Module responsible for re-ordering out of order rtp packets.
  """

  require Logger

  import Bitwise

  @defult_buffer_size 64

  @type t :: %__MODULE__{
          buffer_size: non_neg_integer(),
          intialized: boolean(),
          packets: :array.array(),
          expected_seq_no: non_neg_integer(),
          abs_pos: non_neg_integer()
        }

  @enforce_keys [:buffer_size]
  defstruct @enforce_keys ++ [intialized: false, packets: nil, expected_seq_no: nil, abs_pos: 0]

  @doc """
  Create a new packet re-orderer
  """
  @spec new(non_neg_integer()) :: t()
  def new(buffer_size \\ @defult_buffer_size) do
    %__MODULE__{buffer_size: buffer_size}
  end

  @doc """
  Process a new rtp packet.
  """
  @spec process(ExRTP.Packet.t(), t()) :: {[ExRTP.Packet.t()], t()}
  def process(packet, %__MODULE__{intialized: false} = jitter_buffer) do
    {[packet],
     %{
       jitter_buffer
       | intialized: true,
         packets: :array.new(jitter_buffer.buffer_size, default: nil),
         expected_seq_no: packet.sequence_number + 1
     }}
  end

  def process(packet, %__MODULE__{} = jitter_buffer) do
    Logger.debug("Processing packet with sequence number: #{packet.sequence_number}")
    do_process(jitter_buffer, packet, packet.sequence_number - jitter_buffer.expected_seq_no)
  end

  defp do_process(jitter_buffer, _packet, rel_pos) when rel_pos < 0 do
    {[], jitter_buffer}
  end

  defp do_process(jitter_buffer, packet, 0) do
    indexes =
      do_get_indexes(
        jitter_buffer.packets,
        jitter_buffer.abs_pos + 1,
        jitter_buffer.buffer_size - 1,
        []
      )

    {packets, result} =
      Enum.reduce(indexes, {jitter_buffer.packets, []}, fn idx, {arr, result} ->
        packet = :array.get(idx, arr)
        {:array.reset(idx, arr), [packet | result]}
      end)

    abs_pos = jitter_buffer.abs_pos + length(indexes) + 1 &&& jitter_buffer.buffer_size - 1
    expected_seq_no = packet.sequence_number + length(indexes) + 1

    seq = List.last([packet | result]).sequence_number

    if seq + 1 != expected_seq_no do
      IO.inspect({seq, expected_seq_no})
      IO.inspect(Enum.map(result, & &1.sequence_number), limit: :infinity)
    end

    {[packet | result],
     %{jitter_buffer | packets: packets, abs_pos: abs_pos, expected_seq_no: expected_seq_no}}
  end

  defp do_process(jitter_buffer, packet, rel_pos) when rel_pos >= jitter_buffer.buffer_size do
    buf_size = jitter_buffer.buffer_size - 1

    {packets, result} =
      Enum.reduce(0..(jitter_buffer.buffer_size - 1), {jitter_buffer.packets, []}, fn idx,
                                                                                      {arr,
                                                                                       result} ->
        index = jitter_buffer.abs_pos + idx &&& buf_size

        case :array.get(index, arr) do
          nil -> {arr, result}
          packet -> {:array.reset(index, arr), [packet | result]}
        end
      end)

    {Enum.reverse([packet | result]),
     %{jitter_buffer | packets: packets, expected_seq_no: packet.sequence_number + 1}}
  end

  defp do_process(jitter_buffer, packet, rel_pos) do
    p = jitter_buffer.abs_pos + rel_pos &&& jitter_buffer.buffer_size - 1
    {[], %{jitter_buffer | packets: :array.set(p, packet, jitter_buffer.packets)}}
  end

  defp do_get_indexes(packets, abs_pos, buffer_size, indexes) do
    index = abs_pos &&& buffer_size

    case :array.get(index, packets) do
      nil -> indexes
      _packet -> do_get_indexes(packets, abs_pos + 1, buffer_size, [index | indexes])
    end
  end
end
