defmodule RTSPTest do
  use ExUnit.Case, async: true

  setup do
    pid = start_supervised!({Membrane.RTSP.Server, [port: 0, handler: RTSP.Server.Handler]})
    {:ok, port} = Membrane.RTSP.Server.port_number(pid)
    %{server_pid: pid, port: port}
  end

  test "stream audio", %{port: server_port} do
    assert {:ok, client_pid} =
             RTSP.start_link(
               stream_uri: "rtsp://127.0.0.1:#{server_port}",
               allowed_media_types: [:audio]
             )

    assert {:ok, [track]} = RTSP.connect(client_pid)

    assert %{
             type: :audio,
             control_path: "/audio.aac",
             rtpmap: %{
               payload_type: 98,
               encoding: "mpeg4-generic",
               clock_rate: 44100,
               params: 2
             }
           } = track

    assert :ok = RTSP.play(client_pid)

    assert {adts_packets, <<>>} =
             File.read!("./test/fixtures/streams/audio.aac")
             |> MediaCodecs.MPEG4.parse_adts_stream!()

    {samples, timestamps} = do_collect_samples(client_pid, "/audio.aac") |> Enum.unzip()
    assert length(samples) == length(adts_packets)

    expected_payloads = Enum.map(adts_packets, & &1.frames)
    expected_timestamps = Stream.iterate(0, &(&1 + 1024)) |> Enum.take(length(adts_packets))

    assert samples == expected_payloads
    assert timestamps == expected_timestamps
  end

  defp do_collect_samples(pid, control_path, acc \\ []) do
    receive do
      {:rtsp, ^pid, {^control_path, samples}} ->
        new_acc =
          acc ++ Enum.map(samples, fn {payload, timestamp, _, _} -> {payload, timestamp} end)

        do_collect_samples(pid, control_path, new_acc)
    after
      500 -> acc
    end
  end
end
