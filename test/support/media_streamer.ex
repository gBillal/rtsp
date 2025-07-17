defmodule RTSP.MediaStreamer do
  @moduledoc false

  alias RTSP.RTP.Encoder.MPEG4Audio

  def start_streaming(stream_opts, session_config) do
    stream_opts[:location]
    |> File.stream!(1024)
    |> parse(stream_opts[:encoding])
    |> payload(stream_opts[:encoding], stream_opts[:payload_type], session_config)
    |> Stream.map(&ExRTP.Packet.encode/1)
    |> send_data(session_config)
  end

  defp parse(stream, :aac) do
    Stream.transform(stream, <<>>, &MediaCodecs.MPEG4.parse_adts_stream!(&2 <> &1))
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

  defp send_data(stream, %{transport: :TCP} = config) do
    {channel_num, _rtcp_channel_num} = config.channels

    Enum.each(stream, fn data ->
      payload = <<"$", channel_num::8, byte_size(data)::16, data::binary>>
      :gen_tcp.send(config.tcp_socket, payload)
    end)
  end
end
