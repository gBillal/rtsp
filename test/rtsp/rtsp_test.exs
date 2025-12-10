defmodule RTSPTest do
  alias RTSP.MediaStreamer
  use ExUnit.Case, async: true

  doctest RTSP.RTP.Decoder.AV1.AggregationHeader

  setup do
    pid =
      start_supervised!(
        {Membrane.RTSP.Server,
         [port: 0, handler: RTSP.Server.Handler, udp_rtp_port: 0, udp_rtcp_port: 0]}
      )

    {:ok, port} = Membrane.RTSP.Server.port_number(pid)
    %{server_pid: pid, port: port}
  end

  describe "check states" do
    test "return error when playing without connecting", ctx do
      assert {:ok, client} = RTSP.start_link(stream_uri: "rtsp://127.0.0.1:#{ctx.port}")
      assert {:error, :invalid_state} = RTSP.play(client)
    end

    test "return error when connecting more than once", ctx do
      assert {:ok, client} = RTSP.start_link(stream_uri: "rtsp://127.0.0.1:#{ctx.port}")
      assert {:ok, _tracks} = RTSP.connect(client)
      assert {:error, :invalid_state} = RTSP.connect(client)
    end
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

  test "stream video", %{port: server_port} do
    assert {:ok, client_pid} =
             RTSP.start_link(
               stream_uri: "rtsp://127.0.0.1:#{server_port}",
               allowed_media_types: [:video]
             )

    assert {:ok, [track]} = RTSP.connect(client_pid)

    assert %{
             type: :video,
             control_path: "/video.h264",
             rtpmap: %{
               payload_type: 96,
               encoding: "H264",
               clock_rate: 90_000
             }
           } = track

    assert :ok = RTSP.play(client_pid)

    access_units =
      "./test/fixtures/streams/video.h264"
      |> File.stream!(1024)
      |> MediaStreamer.parse(:h264)
      |> Enum.to_list()

    {samples, timestamps} = do_collect_samples(client_pid, "/video.h264") |> Enum.unzip()
    assert length(samples) == length(access_units)

    # 3750 is the duration for each frame
    expected_timestamps = Stream.iterate(0, &(&1 + 3750)) |> Enum.take(length(access_units))

    assert samples == access_units
    assert timestamps == expected_timestamps
  end

  describe "stream video & audio" do
    test "use TCP", ctx do
      run_test(:tcp, ctx.port)
    end

    test "use UDP", ctx do
      run_test({:udp, 10_000, 20_000}, ctx.port)
    end

    defp run_test(transport, server_port) do
      assert {:ok, client_pid} =
               RTSP.start_link(
                 stream_uri: "rtsp://127.0.0.1:#{server_port}",
                 allowed_media_types: [:audio, :video],
                 transport: transport
               )

      assert {:ok, tracks} = RTSP.connect(client_pid)

      assert [
               %{type: :audio, control_path: "/audio.aac"},
               %{type: :video, control_path: "/video.h264"}
             ] = Enum.sort_by(tracks, & &1.type)

      assert :ok = RTSP.play(client_pid)

      expected_aus =
        "./test/fixtures/streams/video.h264"
        |> File.stream!(1024)
        |> MediaStreamer.parse(:h264)
        |> Enum.to_list()

      assert {expected_samples, <<>>} =
               File.read!("./test/fixtures/streams/audio.aac")
               |> MediaCodecs.MPEG4.parse_adts_stream!()

      expected_samples = Enum.map(expected_samples, & &1.frames)

      {aus, _timestamps} = do_collect_samples(client_pid, "/video.h264") |> Enum.unzip()
      {samples, _timestamps} = do_collect_samples(client_pid, "/audio.aac") |> Enum.unzip()

      assert length(aus) == length(expected_aus)
      assert length(samples) == length(expected_samples)

      assert aus == expected_aus
      assert samples == expected_samples

      assert :ok = RTSP.stop(client_pid)
    end
  end

  defp do_collect_samples(pid, control_path, acc \\ []) do
    receive do
      {:rtsp, ^pid, {^control_path, samples}} ->
        samples =
          case samples do
            {nalus, timestamp, _sync, _timestamp} ->
              [{nalus, timestamp}]

            samples ->
              Enum.map(samples, fn {payload, timestamp, _, _} -> {payload, timestamp} end)
          end

        do_collect_samples(pid, control_path, acc ++ samples)
    after
      500 -> acc
    end
  end
end
