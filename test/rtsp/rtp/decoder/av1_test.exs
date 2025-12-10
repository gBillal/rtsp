defmodule RTSP.RTP.Decoder.AV1Test do
  use ExUnit.Case, async: true

  alias RTSP.RTP.Decoder.AV1

  test "init state" do
    state = AV1.init([])
    assert state == %{obus: [], last_obu: [], last_timestamp: nil, keyframe?: false}
  end

  test "handle discontinuity" do
    state = AV1.init([])
    state = %{state | obus: [[1, 2]], last_obu: [3], last_timestamp: 1000, keyframe?: true}
    state = AV1.handle_discontinuity(state)
    assert state == %{obus: [], last_obu: [], last_timestamp: nil, keyframe?: false}
  end

  test "Depacketize rtp packets" do
    {_state, tus} =
      Enum.map(1..4, &"test/fixtures/rtp/av1/pkt-#{&1}.bin")
      |> Enum.map(&File.read!/1)
      |> Enum.map(fn data ->
        {:ok, packet} = ExRTP.Packet.decode(data)
        packet
      end)
      |> Enum.reduce({AV1.init([]), []}, fn packet, {state, tus} ->
        case AV1.handle_packet(packet, state) do
          {:ok, nil, new_state} ->
            {new_state, tus}

          {:ok, {tu, timestamp, keyframe?}, new_state} ->
            {new_state, [{tu, timestamp, keyframe?} | tus]}
        end
      end)

    assert [{tu, _, true}] = tus
    assert length(tu) == 2
    assert IO.iodata_to_binary(tu) == File.read!("test/fixtures/rtp/av1/ref.bin")
  end

  test "Depacketize random data" do
    packet = %ExRTP.Packet{
      payload: <<1, 2, 3>>,
      payload_type: 96,
      sequence_number: 0,
      timestamp: 0,
      ssrc: 0
    }

    assert {:error, :invalid_payload} = AV1.handle_packet(packet, AV1.init([]))
  end
end
