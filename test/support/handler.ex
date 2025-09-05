defmodule RTSP.Server.Handler do
  @moduledoc false

  use Membrane.RTSP.Server.Handler

  require Logger

  alias Membrane.RTSP.Response

  @sdp """
  v=0
  o=- 0 0 IN IP4 127.0.0.1
  s=MyVideoSession
  t=0 0
  m=video 0 RTP/AVP 96
  a=control:/video.h264
  a=rtpmap:96 H264/90000
  a=fmtp:96 packetization-mode=1
  m=audio 0 RTP/AVP 98
  a=control:/audio.aac
  a=rtpmap:98 mpeg4-generic/44100/2
  a=fmtp:98 mode=AAC-hbr
  """

  @impl true
  def init(_config) do
    sources = %{
      h264: %{
        encoding: :video,
        location: "test/fixtures/streams/video.h264",
        payload_type: 96,
        clock_rate: 90000
      },
      aac: %{
        encoding: :audio,
        location: "test/fixtures/streams/audio.aac",
        payload_type: 98,
        clock_rate: 44100
      }
    }

    %{sources: sources}
  end

  @impl true
  def handle_open_connection(_conn, state), do: state

  @impl true
  def handle_describe(_req, state) do
    Response.new(200)
    |> Response.with_header("Content-Type", "application/sdp")
    |> Response.with_body(@sdp)
    |> then(&{&1, state})
  end

  @impl true
  def handle_setup(_req, :play, state), do: {Response.new(200), state}

  @impl true
  def handle_play(configured_media_context, state) do
    Enum.each(configured_media_context, fn {control_path, config} ->
      codec =
        case URI.parse(control_path).path do
          "/audio.aac" -> :aac
          "/video.h264" -> :h264
        end

      spawn(fn ->
        # Wait time to allow the server to send the play response
        # before sending media data
        Process.sleep(100)

        options = [
          encoding: codec,
          location: state.sources[codec].location,
          payload_type: state.sources[codec].payload_type
        ]

        RTSP.MediaStreamer.start_streaming(options, config)
      end)
    end)

    {Response.new(200), state}
  end

  @impl true
  def handle_pause(state) do
    {Response.new(501), state}
  end

  @impl true
  def handle_teardown(state) do
    {Response.new(200), state}
  end

  @impl true
  def handle_closed_connection(_state), do: :ok
end
