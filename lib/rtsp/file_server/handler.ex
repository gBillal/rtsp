defmodule RTSP.FileServer.Handler do
  @moduledoc false

  use Membrane.RTSP.Server.Handler

  require Logger

  alias Membrane.RTSP.Response
  alias RTSP.FileServer.MediaStreamer

  @impl true
  def init(config) do
    %{files: config[:files], streamer: nil}
  end

  @impl true
  def handle_open_connection(_conn, state), do: state

  @impl true
  def handle_describe(request, state) do
    path = URI.parse(request.path).path

    with %{location: location} <- Enum.find(state.files, &(&1.path == path)),
         {:ok, streamer} <- MediaStreamer.start_link(path: location, loop: state[:loop]) do
      sdp = %ExSDP{
        origin: %ExSDP.Origin{session_id: 0, session_version: 0, address: {127, 0, 0, 1}},
        media: MediaStreamer.sdp_medias(streamer)
      }

      respose =
        Response.new(200)
        |> Response.with_header("Content-Type", "application/sdp")
        |> Response.with_body(to_string(sdp))

      {respose, %{state | streamer: streamer}}
    else
      nil ->
        {Response.new(404), state}

      {:error, :unsupported_file} ->
        {Response.new(415), state}
    end
  end

  @impl true
  def handle_setup(_request, :play, state) do
    {Response.new(200), state}
  end

  @impl true
  def handle_play(media_contexts, state) do
    :ok = MediaStreamer.start_streaming(state.streamer, media_contexts)
    {Response.new(200), state}
  end

  @impl true
  def handle_pause(state), do: {Response.new(501), state}

  @impl true
  def handle_teardown(state) do
    :ok = MediaStreamer.stop(state.streamer)
    {Response.new(200), %{state | streamer: nil}}
  end

  @impl true
  def handle_closed_connection(state) do
    if state.streamer, do: MediaStreamer.stop(state.streamer)
  end
end
