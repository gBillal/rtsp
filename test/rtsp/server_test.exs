defmodule RTSP.ServerTest do
  use ExUnit.Case, async: true

  alias RTSP.RTP.Encoder

  @sdp """
  v=0
  o=- 0 0 IN IP4 127.0.0.1
  s=-
  m=video 0 RTP/AVP 96
  a=control:track=1
  a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0LAFIxoPE3l/8AiACHAeEQjUA==,aM48gA==
  a=rtpmap:96 H264/15360
  """

  defmodule Handler do
    use RTSP.Server.ClientHandler

    def handle_media(control_path, sample, pid) do
      send(pid, {control_path, sample})
      pid
    end
  end

  setup do
    pid = start_link_supervised!({RTSP.Server, handler: Handler, handler_config: self(), port: 0})
    {:ok, port} = RTSP.Server.port_number(pid)

    %{pid: pid, url: "rtsp://localhost:#{port}"}
  end

  describe "connect to server" do
    test "connect to server", %{url: url} do
      {pid, rtp_socket, rtcp_socket} = publish(url)
      assert is_pid(pid)

      :gen_udp.close(rtp_socket)
      :gen_udp.close(rtcp_socket)
      Membrane.RTSP.close(pid)
    end

    test "play not supported", %{url: url} do
      assert {:ok, pid} = Membrane.RTSP.start_link(url)
      assert {:ok, %{status: 501}} = Membrane.RTSP.describe(pid)
    end
  end

  describe "Publish media" do
    test "publish", %{url: url} do
      {pid, rtp_socket, rtcp_socket} = publish(url)

      reader = ExMP4.Reader.new!("test/fixtures/streams/big_h264_aac.mp4")
      video_track = ExMP4.Reader.track(reader, :video)

      reader
      |> ExMP4.Reader.stream(tracks: [video_track.id])
      |> Stream.map(&ExMP4.Reader.read_sample(reader, &1))
      |> Stream.transform(Encoder.H264.init(payload_type: 96), fn sample, encoder ->
        nalus = for <<size::32, nalu::binary-size(size) <- sample.payload>>, do: nalu
        Encoder.H264.handle_sample(nalus, sample.pts, encoder)
      end)
      |> Stream.map(&ExRTP.Packet.encode/1)
      |> Enum.each(&:gen_udp.send(rtp_socket, &1))

      for _idx <- 1..video_track.sample_count do
        assert_receive {"track=1", {payload, _dts, _pts, timestamp}}
        assert is_list(payload)
        assert is_integer(timestamp)
      end

      refute_receive {"track=id", _}

      :gen_udp.close(rtp_socket)
      :gen_udp.close(rtcp_socket)
      Membrane.RTSP.close(pid)
      Process.sleep(100)
    end
  end

  defp publish(url) do
    assert {:ok, pid} = Membrane.RTSP.start_link(url)

    assert {:ok, %{status: 200}} =
             Membrane.RTSP.announce(pid, [{"Content-Type", "application/sdp"}], @sdp)

    {:ok, rtp_socket} = :gen_udp.open(0, [:binary, active: false])
    {:ok, rtcp_socket} = :gen_udp.open(0, [:binary, active: false])

    {:ok, rtp_port} = :inet.port(rtp_socket)
    {:ok, rtcp_port} = :inet.port(rtcp_socket)

    assert {:ok, %{status: 200} = resp} =
             Membrane.RTSP.setup(pid, "/track=1", [
               {"Transport", "RTP/AVP;unicast;client_port=#{rtp_port}-#{rtcp_port};mode=record"}
             ])

    :ok = :gen_udp.connect(rtp_socket, {127, 0, 0, 1}, server_port(resp))

    assert {:ok, %{status: 200}} = Membrane.RTSP.record(pid)

    {pid, rtp_socket, rtcp_socket}
  end

  defp server_port(resp) do
    resp
    |> Membrane.RTSP.Response.get_header("Transport")
    |> elem(1)
    |> String.split(";")
    |> Enum.find(&String.starts_with?(&1, "server_port="))
    |> String.slice(12..-1//1)
    |> String.split("-")
    |> List.first()
    |> String.to_integer()
  end
end
