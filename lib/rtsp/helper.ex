defmodule RTSP.Helper do
  @moduledoc false

  alias RTSP.RTP.Decoder

  @spec decode_rtp!(binary()) :: ExRTP.Packet.t()
  def decode_rtp!(packet) do
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

  @spec parser(atom(), ExSDP.Attribute.FMTP.t()) :: {module(), any()}
  def parser(:h264, fmtp) do
    sps = fmtp.sprop_parameter_sets && fmtp.sprop_parameter_sets.sps
    pps = fmtp.sprop_parameter_sets && fmtp.sprop_parameter_sets.pps

    {Decoder.H264, Decoder.H264.init(sps: sps, pps: pps)}
  end

  def parser(:h265, fmtp) do
    parser_state =
      Decoder.H265.init(
        vps: List.wrap(fmtp && fmtp.sprop_vps) |> Enum.map(&clean_parameter_set/1),
        sps: List.wrap(fmtp && fmtp.sprop_sps) |> Enum.map(&clean_parameter_set/1),
        pps: List.wrap(fmtp && fmtp.sprop_pps) |> Enum.map(&clean_parameter_set/1)
      )

    {Decoder.H265, parser_state}
  end

  def parser(:av1, _fmtp) do
    {Decoder.AV1, Decoder.AV1.init([])}
  end

  def parser(:"mpeg4-generic", %{mode: :AAC_hbr}) do
    {Decoder.MPEG4Audio, Decoder.MPEG4Audio.init(:hbr)}
  end

  def parser(:"mpeg4-generic", %{mode: :AAC_lbr}) do
    {Decoder.MPEG4Audio, Decoder.MPEG4Audio.init(:lbr)}
  end

  def parser(:opus, _fmtp) do
    {Decoder.Opus, Decoder.Opus.init([])}
  end

  def parser(codec, _fmtp) when codec in [:pcmu, :pcma] do
    {Decoder.G711, Decoder.G711.init([])}
  end

  def parser(other_codec, _fmtp) do
    raise "Unsupported codec for RTP depayloader: #{inspect(other_codec)}"
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
