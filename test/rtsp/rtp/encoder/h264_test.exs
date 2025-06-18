defmodule RTSP.RTP.Encoder.H264Test do
  use ExUnit.Case, async: true

  alias RTSP.RTP.Encoder.H264

  @sammple2 <<0, 0, 0, 1, 65, 154, 33, 108, 70, 127, 0, 198, 246, 158, 35, 146, 27, 67, 251, 151,
              239, 136>>

  test "encode an access unit" do
    sample = File.read!("test/fixtures/sample.h264")

    state = H264.init(payload_type: 96)
    assert state.sequence_number > 0
    assert state.sequence_number <= 65535

    assert {packets, state} = H264.handle_sample(sample, 1000, state)
    assert length(packets) == 4
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

    assert {[packet], _state} = H264.handle_sample(@sammple2, 1000, state)
    assert last_packet.sequence_number + 1 == packet.sequence_number
    assert packet.payload == binary_part(@sammple2, 4, byte_size(@sammple2) - 4)
  end
end
