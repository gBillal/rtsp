defmodule RTSP.FileServer.MediaStreamerTest do
  use ExUnit.Case, async: true

  alias RTSP.FileServer.MediaStreamer

  @h264_aac "test/fixtures/streams/big_h264_aac.mp4"
  @hevc_opus "test/fixtures/streams/big_hevc_opus.mp4"

  describe "init/1" do
    test "starts successfully with a valid MP4 file" do
      assert {:ok, _pid} =
               start_supervised({MediaStreamer, path: @h264_aac, rate_control: false})
    end

    test "returns an error for a non-existent file" do
      assert {:error, _reason} =
               MediaStreamer.start_link(path: "/nonexistent.mp4", rate_control: false)
    end
  end

  describe "sdp_medias/1" do
    test "returns two tracks for the H264+AAC fixture" do
      pid = start_link_supervised!({MediaStreamer, path: @h264_aac, rate_control: false})
      assert length(MediaStreamer.sdp_medias(pid)) == 2
    end

    test "returns two tracks for the HEVC+Opus fixture" do
      pid = start_link_supervised!({MediaStreamer, path: @hevc_opus, rate_control: false})
      assert length(MediaStreamer.sdp_medias(pid)) == 2
    end
  end

  describe "start_streaming/2" do
    test "sends RTP packets on all tracks and terminates normally" do
      {track1, track2} = stream_and_collect(@h264_aac)

      assert length(track1) > 0
      assert length(track2) > 0
    end

    test "RTP timestamps are non-decreasing within each track" do
      {track1, track2} = stream_and_collect(@hevc_opus)

      for packets <- [track1, track2] do
        timestamps = Enum.map(packets, &rtp_timestamp/1)
        assert timestamps == Enum.sort(timestamps)
      end
    end
  end

  describe "loop option" do
    test "loop: 1 sends exactly twice as many packets as loop: false" do
      {no_loop, _} = stream_and_collect(@h264_aac)
      {looped, _} = stream_and_collect(@h264_aac, loop: 1)

      assert length(looped) == 2 * length(no_loop)
    end

    test "RTP timestamps are non-decreasing across loop boundaries" do
      # Collect packets for a single play to know where the boundary is.
      {no_loop, _} = stream_and_collect(@h264_aac)
      {looped, _} = stream_and_collect(@h264_aac, loop: 1)

      n = length(no_loop)
      first_play = Enum.take(looped, n)
      second_play = Enum.drop(looped, n)

      max_first = first_play |> Enum.map(&rtp_timestamp/1) |> Enum.max()
      min_second = second_play |> Enum.map(&rtp_timestamp/1) |> Enum.min()

      assert min_second > max_first
    end
  end

  describe "TCP connection errors" do
    test "stops normally when the TCP socket is closed before the first send" do
      pid = start_link_supervised!({MediaStreamer, path: @h264_aac, rate_control: false})
      ref = Process.monitor(pid)

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, listen_port} = :inet.port(listen)
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, listen_port, [:binary, active: false])
      {:ok, _server} = :gen_tcp.accept(listen, 500)
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)

      :ok =
        MediaStreamer.start_streaming(pid, [
          {"track=1", %{transport: :TCP, ssrc: 1, tcp_socket: socket, channels: {0, 1}}}
        ])

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end
  end

  describe "stop/1" do
    test "stops the server cleanly before streaming starts" do
      pid = start_link_supervised!({MediaStreamer, path: @h264_aac, rate_control: false})
      ref = Process.monitor(pid)

      assert :ok = MediaStreamer.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  defp rtp_timestamp(<<_::32, ts::32, _::binary>>), do: ts

  # Streams the given file to completion with two UDP sockets and returns
  # the packets collected on each track socket.
  defp stream_and_collect(path, opts \\ []) do
    {:ok, pid} = MediaStreamer.start_link([path: path, rate_control: false] ++ opts)
    ref = Process.monitor(pid)

    {s1, p1} = open_udp_socket()
    {s2, p2} = open_udp_socket()

    contexts = [
      {"track=1", udp_context(s1, p1)},
      {"track=2", udp_context(s2, p2)}
    ]

    :ok = MediaStreamer.start_streaming(pid, contexts)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000

    track1 = collect_packets(s1)
    track2 = collect_packets(s2)

    :gen_udp.close(s1)
    :gen_udp.close(s2)

    {track1, track2}
  end

  defp collect_packets(socket, acc \\ []) do
    case :gen_udp.recv(socket, 0, 100) do
      {:ok, {_addr, _port, data}} -> collect_packets(socket, [data | acc])
      {:error, :timeout} -> Enum.reverse(acc)
    end
  end

  defp open_udp_socket do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, recbuf: 10_000_000])
    {:ok, port} = :inet.port(socket)
    {socket, port}
  end

  defp udp_context(socket, port) do
    %{
      transport: :UDP,
      ssrc: :rand.uniform(0xFFFFFFFF),
      rtp_socket: socket,
      address: {127, 0, 0, 1},
      client_port: {port, port + 1}
    }
  end
end
