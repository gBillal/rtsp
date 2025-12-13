defmodule RTSP.RTP.EncodeDecodeTest do
  use ExUnit.Case, async: true

  alias RTSP.RTP.Encoder
  alias RTSP.RTP.Decoder

  @pcmu_fixture "test/fixtures/streams/audio_16khz.mulaw"

  test "Payload and depayload PCM mulaw" do
    decoder = Decoder.G711.init([])

    packets =
      @pcmu_fixture
      |> File.stream!([], 640)
      |> Enum.flat_map_reduce({Encoder.G711.init([]), 0}, fn data, {encoder, timestamp} ->
        {packets, encoder} = Encoder.G711.handle_sample(data, timestamp, encoder)
        {packets, {encoder, timestamp + byte_size(data)}}
      end)
      |> elem(0)

    decoded_data =
      Enum.reduce(packets, {decoder, <<>>}, fn packet, {decoder, acc} ->
        {:ok, {data, _timestamp, _}, decoder} = Decoder.G711.handle_packet(packet, decoder)
        {decoder, acc <> data}
      end)
      |> elem(1)

    assert File.read!(@pcmu_fixture) == decoded_data
  end
end
