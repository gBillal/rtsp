defmodule RTSPTest do
  use ExUnit.Case, async: true

  doctest RTSP.RTP.Decoder.AV1.AggregationHeader

  @paths [
    {"/hevc_opus", "test/fixtures/streams/big_hevc_opus.mp4"},
    {"/h264_aac", "test/fixtures/streams/big_h264_aac.mp4"}
  ]

  setup do
    files = Enum.map(@paths, &%{path: elem(&1, 0), location: elem(&1, 1)})

    pid =
      start_supervised!(
        {RTSP.FileServer,
         [port: 0, files: files, udp_rtp_port: 0, udp_rtcp_port: 0, rate_control: false]}
      )

    {:ok, port} = RTSP.FileServer.port_number(pid)
    %{server_pid: pid, port: port}
  end

  describe "check states" do
    test "return error when playing without connecting", ctx do
      assert {:ok, client} = RTSP.start_link(stream_uri: "rtsp://127.0.0.1:#{ctx.port}")
      assert {:error, :invalid_state} = RTSP.play(client)
    end

    test "return error when connecting more than once", ctx do
      assert {:ok, client} = RTSP.start_link(stream_uri: "rtsp://127.0.0.1:#{ctx.port}/hevc_opus")
      assert {:ok, _tracks} = RTSP.connect(client)
      assert {:error, :invalid_state} = RTSP.connect(client)
    end
  end

  test "stream audio", %{port: server_port} do
    assert {:ok, client_pid} =
             RTSP.start_link(
               stream_uri: "rtsp://127.0.0.1:#{server_port}/hevc_opus",
               allowed_media_types: [:audio]
             )

    assert {:ok, [track]} = RTSP.connect(client_pid)

    assert %{
             type: :audio,
             control_path: "track=2",
             rtpmap: %{
               payload_type: 97,
               encoding: "OPUS",
               clock_rate: 48000,
               params: 2
             }
           } = track

    assert :ok = RTSP.play(client_pid)

    reader = ExMP4.Reader.new!("test/fixtures/streams/big_hevc_opus.mp4")
    track = ExMP4.Reader.track(reader, :audio)
    expected_samples = read_samples(reader, track)

    {samples, timestamps} = do_collect_samples(client_pid, "track=2") |> Enum.unzip()
    assert length(samples) == length(expected_samples)
    assert Enum.map(expected_samples, & &1.payload) == samples
    assert Enum.map(expected_samples, & &1.dts) == timestamps

    ExMP4.Reader.close(reader)
  end

  test "stream video", %{port: server_port} do
    assert {:ok, client_pid} =
             RTSP.start_link(
               stream_uri: "rtsp://127.0.0.1:#{server_port}/hevc_opus",
               allowed_media_types: [:video]
             )

    assert {:ok, [track]} = RTSP.connect(client_pid)

    assert %{
             type: :video,
             control_path: "track=1",
             rtpmap: %{
               payload_type: 96,
               encoding: "H265",
               clock_rate: 90_000
             }
           } = track

    assert :ok = RTSP.play(client_pid)

    reader = ExMP4.Reader.new!("test/fixtures/streams/big_hevc_opus.mp4")
    track = ExMP4.Reader.track(reader, :video)
    expected_samples = read_samples(reader, track)

    {samples, _timestamps} = do_collect_samples(client_pid, "track=1") |> Enum.unzip()
    assert length(samples) == length(expected_samples)

    assert Enum.map(expected_samples, & &1.payload) ==
             Enum.map(samples, &delete_parameter_sets(&1, track.media))

    ExMP4.Reader.close(reader)
  end

  for {path, fixture} <- @paths do
    describe "stream video & audio: #{path}" do
      test "use TCP", ctx do
        run_test(:tcp, ctx.port, unquote(path), unquote(fixture))
      end

      test "use UDP", ctx do
        run_test({:udp, 10_000, 20_000}, ctx.port, unquote(path), unquote(fixture))
      end
    end
  end

  defp run_test(transport, server_port, path, fixture) do
    assert {:ok, client_pid} =
             RTSP.start_link(
               stream_uri: "rtsp://127.0.0.1:#{server_port}#{path}",
               allowed_media_types: [:audio, :video],
               transport: transport
             )

    assert {:ok, tracks} = RTSP.connect(client_pid)

    assert [
             %{type: :audio, control_path: "track=2"},
             %{type: :video, control_path: "track=1"}
           ] = Enum.sort_by(tracks, & &1.type)

    assert :ok = RTSP.play(client_pid)

    reader = ExMP4.Reader.new!(fixture)
    audio_track = ExMP4.Reader.track(reader, :audio)
    video_track = ExMP4.Reader.track(reader, :video)
    expected_audio_samples = read_samples(reader, audio_track)
    expected_video_samples = read_samples(reader, video_track)

    {aus, _timestamps} = do_collect_samples(client_pid, "track=1") |> Enum.unzip()
    {samples, _timestamps} = do_collect_samples(client_pid, "track=2") |> Enum.unzip()

    assert length(aus) == length(expected_video_samples)
    assert length(samples) == length(expected_audio_samples)

    assert Enum.map(expected_video_samples, & &1.payload) ==
             Enum.map(aus, &delete_parameter_sets(&1, video_track.media))

    assert samples == Enum.map(expected_audio_samples, & &1.payload)

    assert :ok = RTSP.stop(client_pid)
    ExMP4.Reader.close(reader)
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

  defp read_samples(reader, track) do
    reader
    |> ExMP4.Reader.stream(tracks: [track.id])
    |> Enum.map(&ExMP4.Reader.read_sample(reader, &1))
    |> Enum.map(&process_sample(&1, track.media))
  end

  defp process_sample(sample, codec) when codec in [:h264, :h265] do
    nalus = for <<size::32, nalu::binary-size(size) <- sample.payload>>, do: nalu
    %{sample | payload: delete_parameter_sets(nalus, codec)}
  end

  defp process_sample(sample, _codec), do: sample

  defp delete_parameter_sets(nalus, :h264) do
    Enum.reject(nalus, &(MediaCodecs.H264.NALU.type(&1) in [:sps, :pps]))
  end

  defp delete_parameter_sets(nalus, :h265) do
    Enum.reject(nalus, &(MediaCodecs.H265.NALU.type(&1) in [:vps, :sps, :pps]))
  end

  defp delete_parameter_sets(other, _codec), do: other
end
