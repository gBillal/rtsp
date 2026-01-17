defmodule RTSP.RTP.Decoder.H265.FU do
  @moduledoc false
  # Module responsible for parsing H265 Fragmentation Unit.
  #
  # FU packet header
  # ```
  #  +---------------+
  #  |0|1|2|3|4|5|6|7|
  #  +-+-+-+-+-+-+-+-+
  #  |S|E| FuType    |
  #  +---------------+
  # ```

  import Bitwise

  alias RTSP.RTP.Decoder.H265.NAL

  defstruct [:last_seq_num, data: [], type: nil, donl?: false, don: nil]

  @type don :: nil | non_neg_integer()

  @type t :: %__MODULE__{
          data: iodata(),
          last_seq_num: nil | non_neg_integer(),
          type: NAL.Header.type(),
          donl?: boolean(),
          don: don()
        }

  defguardp is_next(last_seq_num, next_seq_num) when (last_seq_num + 1 &&& 65_535) == next_seq_num

  @doc """
  Parses H265 Fragmentation Unit

  If a packet that is being parsed is not considered last then a `{:incomplete, t()}`
  tuple  will be returned.
  In case of last packet `{:ok, {type, data, don}}` tuple will be returned, where data
  is `NAL Unit` created by concatenating subsequent Fragmentation Units and `don` is the
  decoding order number of the `NAL unit` in case `donl` field is present in the packet.
  """
  @spec parse(binary(), non_neg_integer(), t) ::
          {:ok, {binary(), NAL.Header.type(), don()}}
          | {:error, :packet_malformed | :invalid_first_packet}
          | {:incomplete, t()}
  def parse(<<1::1, 1::1, _rest::bitstring>>, _seq_num, _acc) do
    {:error, :packet_malformed}
  end

  def parse(<<firstbit::1, secondbit::1, type::6, rest::binary>>, seq_num, acc) do
    do_parse({firstbit, secondbit}, rest, seq_num, %{acc | type: type})
  end

  @doc """
  Serialize H265 unit into list of FU payloads
  """
  @spec serialize(binary(), pos_integer()) :: list(binary()) | {:error, :unit_too_small}
  def serialize(data, preferred_size) do
    case data do
      <<r::1, type::6, h_r::9, head::binary-size(preferred_size - 3), rest::binary>> ->
        header = <<r::1, NAL.Header.encode_type(:fu)::6, h_r::9>>
        payload = <<header::binary, 1::1, 0::1, type::6, head::binary>>
        [payload | do_serialize(rest, header, type, preferred_size - 3)]

      _data ->
        {:error, :unit_too_small}
    end
  end

  defp do_serialize(data, header, type, preferred_size) do
    case data do
      <<head::binary-size(preferred_size), rest::binary>> when byte_size(rest) > 0 ->
        payload = <<header::binary, 0::1, 0::1, type::6, head::binary>>
        [payload | do_serialize(rest, header, type, preferred_size)]

      rest ->
        [<<header::binary, 0::1, 1::1, type::6, rest::binary>>]
    end
  end

  defp do_parse(header, data, seq_num, acc)

  defp do_parse({1, _}, data, seq_num, %{donl?: false} = acc) do
    {:incomplete, %{acc | data: [data], last_seq_num: seq_num}}
  end

  defp do_parse({1, _}, <<don::16, data::binary>>, seq_num, acc) do
    {:incomplete, %{acc | data: [data], last_seq_num: seq_num, don: don}}
  end

  defp do_parse({0, _}, _data, _seq_num, %__MODULE__{last_seq_num: nil}) do
    {:error, :invalid_first_packet}
  end

  defp do_parse({_, 1}, data, seq_num, acc) when is_next(acc.last_seq_num, seq_num) do
    {:ok, {Enum.reverse([data | acc.data]), acc.type, acc.don}}
  end

  defp do_parse(_header, data, seq_num, %__MODULE__{data: acc, last_seq_num: last} = fu)
       when is_next(last, seq_num),
       do: {:incomplete, %__MODULE__{fu | data: [data | acc], last_seq_num: seq_num}}

  defp do_parse(_header, _data, _seq_num, _fu), do: {:error, :missing_packet}
end
