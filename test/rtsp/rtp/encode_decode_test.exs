defmodule RTSP.RTP.EncodeDecodeTest do
  use ExUnit.Case, async: true

  alias RTSP.RTP.Encoder
  alias RTSP.RTP.Decoder

  @pcmu_fixture "test/fixtures/streams/audio_16khz.mulaw"
  @obus <<10, 14, 0, 0, 0, 66, 167, 191, 229, 227, 87, 204, 128, 128, 128, 146, 50, 202, 2, 16, 0,
          133, 128, 128, 130, 4, 16, 0, 128, 2, 221, 109, 86, 159, 249, 27, 179, 222, 27, 222,
          241, 93, 48, 100, 197, 46, 230, 228, 64, 62, 84, 241, 55, 169, 146, 118, 150, 244, 181,
          79, 172, 255, 25, 233, 201, 168, 202, 77, 178, 173, 86, 8, 132, 143, 234, 214, 92, 82,
          10, 43, 28, 246, 114, 109, 112, 31, 5, 47, 13, 250, 165, 6, 138, 132, 8, 199, 113, 36,
          210, 142, 179, 247, 93, 208, 186, 35, 14, 87, 12, 205, 109, 7, 111, 156, 169, 141, 159,
          92, 224, 155, 203, 81, 178, 17, 72, 209, 37, 50, 234, 99, 108, 17, 32, 96, 211, 135, 9,
          200, 217, 222, 8, 163, 22, 239, 30, 105, 6, 113, 178, 140, 237, 185, 113, 242, 152, 225,
          124, 72, 54, 235, 106, 15, 110, 208, 48, 235, 245, 116, 1, 16, 10, 153, 16, 58, 69, 205,
          41, 60, 189, 149, 94, 224, 170, 7, 229, 67, 105, 132, 95, 234, 158, 151, 41, 19, 242,
          152, 36, 10, 149, 128, 161, 108, 85, 126, 92, 138, 31, 72, 11, 74, 185, 137, 15, 249,
          175, 110, 145, 141, 38, 75, 121, 12, 148, 101, 121, 246, 121, 134, 245, 253, 58, 154,
          212, 244, 157, 192, 66, 118, 171, 162, 26, 185, 211, 55, 85, 239, 184, 181, 146, 100,
          107, 180, 13, 164, 184, 60, 66, 226, 124, 231, 107, 145, 226, 237, 185, 25, 46, 234, 10,
          151, 249, 153, 27, 89, 157, 4, 37, 170, 154, 245, 158, 125, 96, 235, 53, 122, 123, 11,
          96, 99, 248, 65, 221, 85, 209, 212, 134, 178, 172, 40, 10, 240, 56, 161, 126, 59, 48,
          63, 207, 150, 103, 166, 150, 28, 86, 90, 188, 196, 235, 221, 251, 29, 138, 181, 81, 68,
          150, 65, 118, 228, 185, 189, 187, 116, 94, 145, 81, 246, 195, 125, 90, 242, 107, 50,
          188, 241, 230, 98, 144>>

  describe "Payload and depayload" do
    test "PCM mulaw" do
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

    for payload_size <- [100, 200, 400, 800, 1600] do
      test "av1 with max payload size: #{payload_size}" do
        encoder = Encoder.AV1.init(max_payload_size: unquote(payload_size))
        decoder = Decoder.AV1.init([])

        # <<12, 00>> is a temporal delimiter OBU
        {packets, _state} = Encoder.AV1.handle_sample(<<0x12, 0x00>> <> @obus, 0, encoder)

        {decoded_data, _state} =
          Enum.reduce(packets, {[], decoder}, fn packet, {tu, decoder} ->
            case Decoder.AV1.handle_packet(packet, decoder) do
              {:ok, {data, 0, true}, decoder} ->
                {tu ++ data, decoder}

              {:ok, nil, decoder} ->
                {tu, decoder}
            end
          end)

        decoded_data =
          decoded_data
          |> Enum.map(&MediaCodecs.AV1.OBU.set_size_flag/1)
          |> IO.iodata_to_binary()

        assert decoded_data == @obus
      end
    end
  end
end
