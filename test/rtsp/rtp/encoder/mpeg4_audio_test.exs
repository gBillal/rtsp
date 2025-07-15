defmodule RTSP.RTP.Encoder.MPEG4AudioTest do
  use ExUnit.Case, async: true

  alias RTSP.RTP.Encoder.MPEG4Audio

  test "encode AAC hbr" do
    encoder = MPEG4Audio.init(mode: :hbr)

    frames = [
      {<<0xA0, 0xA1>>, 1000},
      {<<0xA2>>, 2024},
      {<<0xA3, 0xA4, 0xA5>>, 3048}
    ]

    encoder =
      Enum.reduce(frames, encoder, fn {frame, timestamp}, encoder ->
        assert {[], encoder} = MPEG4Audio.handle_sample(frame, timestamp, encoder)
        encoder
      end)

    assert [
             %ExRTP.Packet{
               payload: <<0, 48, 0, 16, 0, 8, 0, 24, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5>>,
               timestamp: 1000
             }
           ] = MPEG4Audio.flush(encoder)
  end

  test "encode AAC lbr" do
    encoder = MPEG4Audio.init(mode: :lbr)

    frames = [
      {<<0xA0, 0xA1>>, 2000},
      {<<0xA2>>, 3024},
      {<<0xA3, 0xA4, 0xA5>>, 4048}
    ]

    encoder =
      Enum.reduce(frames, encoder, fn {frame, timestamp}, encoder ->
        assert {[], encoder} = MPEG4Audio.handle_sample(frame, timestamp, encoder)
        encoder
      end)

    assert [
             %ExRTP.Packet{
               payload: <<0, 24, 8, 4, 12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5>>,
               timestamp: 2000
             }
           ] = MPEG4Audio.flush(encoder)
  end

  test "encode large frames" do
    encoder = MPEG4Audio.init(mode: :hbr, max_payload_size: 200)

    frames = [
      {<<0::size(100)-unit(8)>>, 0},
      {<<1::size(80)-unit(8)>>, 1024},
      {<<2::size(120)-unit(8)>>, 2048},
      {<<3::size(40)-unit(8)>>, 3072},
      {<<4::size(50)-unit(8)>>, 4096}
    ]

    packets =
      frames
      |> Stream.transform(
        fn -> encoder end,
        &MPEG4Audio.handle_sample(elem(&1, 0), elem(&1, 1), &2),
        &{MPEG4Audio.flush(&1), &1},
        fn _acc -> :ok end
      )
      |> Enum.to_list()

    assert [
             %ExRTP.Packet{
               payload: <<0, 32, 3, 32, 2, 128, 0::size(100)-unit(8), 1::size(80)-unit(8)>>,
               timestamp: 0
             },
             %ExRTP.Packet{
               payload: <<0, 32, 3, 192, 1, 64, 2::size(120)-unit(8), 3::size(40)-unit(8)>>,
               timestamp: 2048
             },
             %ExRTP.Packet{
               payload: <<0, 16, 1, 144, 4::size(50)-unit(8)>>,
               timestamp: 4096
             }
           ] = packets
  end

  test "raise if sample size is bigger than max payload size" do
    encoder = MPEG4Audio.init(mode: :hbr, max_payload_size: 100)

    assert_raise RuntimeError, fn ->
      MPEG4Audio.handle_sample(<<1::size(101)-unit(8)>>, 0, encoder)
    end
  end
end
