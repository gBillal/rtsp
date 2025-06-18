defmodule RTSP.RTP.Encoder.H265Test do
  use ExUnit.Case, async: true

  alias RTSP.RTP.Encoder.H265

  @sample2 <<0, 0, 0, 1, 2, 1, 208, 9, 126, 16, 198, 16, 178, 65, 192, 253, 193, 38, 220, 168, 44,
             205, 151, 36, 226, 134, 89, 47, 193, 119>>

  test "encode an access unit" do
    sample = File.read!("test/fixtures/sample.h265")

    state = H265.init(payload_type: 96)
    assert state.sequence_number > 0
    assert state.sequence_number <= 65535

    assert {packets, state} = H265.handle_sample(sample, 1000, state)
    assert length(packets) == 6
    assert Enum.all?(packets, &(&1.payload_type == 96))
    assert Enum.all?(packets, &(&1.timestamp == 1000))

    assert packets
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [first, second] ->
             first.sequence_number == second.sequence_number - 1
           end)

    [last_packet | rest] = Enum.reverse(packets)
    assert last_packet.marker
    assert Enum.all?(rest, &(not &1.marker))

    assert {[packet], _state} = H265.handle_sample(@sample2, 1000, state)
    assert last_packet.sequence_number + 1 == packet.sequence_number
    assert packet.payload == binary_part(@sample2, 4, byte_size(@sample2) - 4)
  end
end
