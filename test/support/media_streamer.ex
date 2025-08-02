defmodule RTSP.MediaStreamer do
  @moduledoc false

  alias MediaCodecs.H264.{AccessUnitSplitter, NaluSplitter}
  alias RTSP.RTP.Encoder.{H264, MPEG4Audio}

  def start_streaming(stream_opts, session_config) do
    stream_opts[:location]
    |> File.stream!(1024)
    |> parse(stream_opts[:encoding])
    |> payload(stream_opts[:encoding], stream_opts[:payload_type], session_config)
    |> Stream.map(&ExRTP.Packet.encode/1)
    |> send_data(session_config)
  end

  def parse(stream, :aac) do
    Stream.transform(stream, <<>>, &MediaCodecs.MPEG4.parse_adts_stream!(&2 <> &1))
  end

  def parse(stream, :h264) do
    stream
    |> Stream.transform(
      fn -> NaluSplitter.new() end,
      &NaluSplitter.process/2,
      &{NaluSplitter.flush(&1), &1},
      &Function.identity/1
    )
    |> Stream.transform(
      fn -> AccessUnitSplitter.new() end,
      fn nalu, splitter ->
        case AccessUnitSplitter.process(nalu, splitter) do
          {nil, splitter} -> {[], splitter}
          {access_unit, splitter} -> {[access_unit], splitter}
        end
      end,
      &{[AccessUnitSplitter.flush(&1)], &1},
      &Function.identity/1
    )
  end

  defp payload(stream, :aac, payload_type, config) do
    encoder_opts = [mode: :hbr, ssrc: config[:ssrc], payload_type: payload_type]

    Stream.transform(
      stream,
      fn -> {MPEG4Audio.init(encoder_opts), 0} end,
      fn adts_sample, {encoder, timestamp} ->
        {packets, encoder} = MPEG4Audio.handle_sample(adts_sample.frames, timestamp, encoder)
        {packets, {encoder, timestamp + 1024}}
      end,
      &{MPEG4Audio.flush(elem(&1, 0)), &1},
      fn _ -> :ok end
    )
  end

  defp payload(stream, :h264, payload_type, config) do
    encoder_opts = [ssrc: config[:ssrc], payload_type: payload_type]

    Stream.transform(
      stream,
      fn -> {H264.init(encoder_opts), 0} end,
      fn au, {encoder, timestamp} ->
        {packets, encoder} = H264.handle_sample(au, timestamp, encoder)
        {packets, {encoder, timestamp + 3750}}
      end,
      fn _ -> :ok end
    )
  end

  defp send_data(stream, %{transport: :TCP} = config) do
    {channel_num, _rtcp_channel_num} = config.channels

    Enum.each(stream, fn data ->
      payload = <<"$", channel_num::8, byte_size(data)::16, data::binary>>
      :gen_tcp.send(config.tcp_socket, payload)
    end)
  end

  defp send_data(stream, %{transport: :UDP} = config) do
    Enum.each(stream, fn data ->
      :gen_udp.send(config.rtp_socket, config.address, elem(config.client_port, 0), data)
    end)
  end
end
