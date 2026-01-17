defmodule RTSP.RTP.Decoder.H264.FU do
  @moduledoc false
  # Module responsible for parsing H264 Fragmentation Unit.
  #
  #  Fragmentation Unit Header
  #  # ```
  #   +---------------+
  #   |0|1|2|3|4|5|6|7|
  #   +-+-+-+-+-+-+-+-+
  #   |S|E|R|  Type   |
  #   +---------------+
  # ```

  import Bitwise

  alias RTSP.RTP.Decoder.H264.NAL

  defstruct [:last_seq_num, data: []]

  @type t :: %__MODULE__{
          data: iodata(),
          last_seq_num: nil | non_neg_integer()
        }

  defguardp is_next(last_seq_num, next_seq_num) when (last_seq_num + 1 &&& 65_535) == next_seq_num

  @doc """
  Parses H264 Fragmentation Unit

  If a packet that is being parsed is not considered last then a `{:incomplete, t()}`
  tuple  will be returned.
  In case of last packet `{:ok, {type, data}}` tuple will be returned, where data
  is `NAL Unit` created by concatenating subsequent Fragmentation Units.
  """
  @spec parse(binary(), non_neg_integer(), t) ::
          {:ok, {binary(), NAL.Header.type()}}
          | {:error, :packet_malformed | :invalid_first_packet}
          | {:incomplete, t()}
  def parse(<<1::1, 1::1, _type::bitstring>>, _seq_num, _acc) do
    {:error, :packet_malformed}
  end

  def parse(<<first_f::1, last_f::1, 0::1, type::5, rest::binary>>, seq_num, acc)
      when type in 1..23 do
    do_parse({first_f, last_f, type}, rest, seq_num, acc)
  end

  def parse(_data, _seq_num, _acc), do: {:error, :invalid_packet}

  @doc """
  Serialize H264 unit into list of FU-A payloads
  """
  @spec serialize(binary(), pos_integer()) :: list(binary()) | {:error, :unit_too_small}
  def serialize(data, preferred_size) do
    case data do
      <<h_p::3, type::5, fragment::binary-size(preferred_size - 2), rest::binary>> ->
        header = <<h_p::3, NAL.Header.encode_type(:fu_a)::5>>
        payload = <<header::binary, 1::1, 0::1, 0::1, type::5, fragment::binary>>
        [payload | do_serialize(rest, header, type, preferred_size - 2)]

      _data ->
        {:error, :unit_too_small}
    end
  end

  defp do_serialize(data, header, type, preferred_size) do
    case data do
      <<fragment::binary-size(preferred_size), rest::binary>> when byte_size(rest) > 0 ->
        payload = <<header::binary, 0::3, type::5, fragment::binary>>
        [payload | do_serialize(rest, header, type, preferred_size)]

      rest ->
        [<<header::binary, 0::1, 1::1, 0::1, type::5, rest::binary>>]
    end
  end

  defp do_parse(header, data, seq_num, acc)

  defp do_parse({1, _, _}, data, seq_num, acc) do
    {:incomplete, %{acc | data: [data], last_seq_num: seq_num}}
  end

  defp do_parse({0, _, _}, _data, _seq_num, %__MODULE__{last_seq_num: nil}) do
    {:error, :invalid_first_packet}
  end

  defp do_parse({_, 1, type}, data, seq_num, acc) when is_next(acc.last_seq_num, seq_num) do
    {:ok, {Enum.reverse([data | acc.data]), type}}
  end

  defp do_parse(_header, data, seq_num, %__MODULE__{data: acc, last_seq_num: last} = fu)
       when is_next(last, seq_num),
       do: {:incomplete, %__MODULE__{fu | data: [data | acc], last_seq_num: seq_num}}

  defp do_parse(_header, _data, _seq_num, _fu), do: {:error, :missing_packet}
end
