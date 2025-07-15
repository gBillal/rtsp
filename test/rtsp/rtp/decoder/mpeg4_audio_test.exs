defmodule RTSP.RTP.Decoder.MPEG4AudioTest do
  use ExUnit.Case, async: true

  alias RTSP.RTP.Decoder.MPEG4Audio

  test "decode AAC hbr" do
    decoder = MPEG4Audio.init(:hbr)

    rtp =
      ExRTP.Packet.new(<<0, 48, 0, 16, 0, 8, 0, 24, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5>>,
        marker: true,
        timestamp: 1000,
        payload_type: 96
      )

    assert {:ok, frames, ^decoder} = MPEG4Audio.handle_packet(rtp, decoder)

    assert [
             {<<0xA0, 0xA1>>, 1000, true},
             {<<0xA2>>, 2024, true},
             {<<0xA3, 0xA4, 0xA5>>, 3048, true}
           ] = frames
  end

  test "decode AAC lbr" do
    decoder = MPEG4Audio.init(:lbr)

    rtp =
      ExRTP.Packet.new(<<0, 24, 8, 4, 12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5>>,
        marker: true,
        timestamp: 2000,
        payload_type: 96
      )

    assert {:ok, frames, ^decoder} = MPEG4Audio.handle_packet(rtp, decoder)

    assert [
             {<<0xA0, 0xA1>>, 2000, true},
             {<<0xA2>>, 3024, true},
             {<<0xA3, 0xA4, 0xA5>>, 4048, true}
           ] = frames
  end
end
