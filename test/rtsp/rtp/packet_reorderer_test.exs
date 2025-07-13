defmodule RTSP.RTP.PacketReordererTest do
  use ExUnit.Case, async: true

  alias RTSP.RTP.PacketReorderer

  test "Initialize packet reorderer" do
    reorderer = PacketReorderer.new()
    assert reorderer.buffer_size == 64

    reorderer = PacketReorderer.new(128)
    assert reorderer.buffer_size == 128
    refute reorderer.initialized

    packet = new_packet(1)

    assert {[^packet], %{initialized: true}} =
             PacketReorderer.process(packet, reorderer)
  end

  test "Process packets" do
    packet1 = new_packet(10)
    packet2 = new_packet(9)
    packet3 = new_packet(11)
    packet4 = new_packet(12)
    packet5 = new_packet(16)
    packet6 = new_packet(14)
    packet7 = new_packet(13)
    packet8 = new_packet(17)
    packet9 = new_packet(99)

    reorderer = PacketReorderer.new(16)

    assert {[^packet1], reorderer} = PacketReorderer.process(packet1, reorderer)
    assert {[], reorderer} = PacketReorderer.process(packet2, reorderer)
    assert {[^packet3], reorderer} = PacketReorderer.process(packet3, reorderer)
    assert {[^packet4], reorderer} = PacketReorderer.process(packet4, reorderer)
    assert {[], reorderer} = PacketReorderer.process(packet5, reorderer)
    assert {[], reorderer} = PacketReorderer.process(packet6, reorderer)
    assert {[^packet7, ^packet6], reorderer} = PacketReorderer.process(packet7, reorderer)
    assert {[], reorderer} = PacketReorderer.process(packet8, reorderer)

    assert {[^packet5, ^packet8, ^packet9], _reorderer} =
             PacketReorderer.process(packet9, reorderer)
  end

  defp new_packet(seq) do
    %ExRTP.Packet{
      sequence_number: seq,
      payload_type: 96,
      timestamp: 0,
      ssrc: 0,
      payload: <<>>
    }
  end
end
