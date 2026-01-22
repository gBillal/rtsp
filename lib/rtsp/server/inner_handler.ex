defmodule RTSP.Server.InnerHandler do
  @moduledoc false

  use Membrane.RTSP.Server.Handler

  require Logger

  alias Membrane.RTSP.Response
  alias RTSP.Server.ClientSession

  @impl true
  def init(config) do
    {:ok, client_session} = ClientSession.start_link(config)
    %{path: nil, client_session: client_session}
  end

  @impl true
  def handle_open_connection(_socket, state), do: state

  @impl true
  def handle_describe(_request, state) do
    {Response.new(501), state}
  end

  @impl true
  def handle_announce(request, state) do
    path = URI.parse(request.path).path

    Logger.debug("[#{path}] Announce request")

    case ClientSession.handle_announce(state.client_session, request) do
      :ok ->
        {Response.new(200), %{state | path: path}}

      {:error, _reason} ->
        {Response.new(452), state}
    end
  end

  @impl true
  def handle_setup(_request, :record, state) do
    Logger.debug("[#{state.path}] Setup request")
    {Response.new(200), state}
  end

  @impl true
  def handle_play(_configured_media_context, state) do
    {Response.new(501), state}
  end

  @impl true
  def handle_record(configured_media_context, state) do
    Logger.debug("[#{state.path}] Record request")

    tracks = ClientSession.tracks(state.client_session)

    cond do
      Enum.any?(configured_media_context, &(elem(&1, 1).transport == :TCP)) ->
        Logger.error("[#{state.path}] Publishing with TCP is not supported")
        {Response.new(461), state}

      not all_tracks_setup?(tracks, configured_media_context) ->
        Logger.error("[#{state.path}] Not all tracks are setup")
        {Response.new(452), state}

      true ->
        ClientSession.start_recording(state.client_session, configured_media_context)

        Enum.each(configured_media_context, fn {_key, ctx} ->
          :ok = :gen_udp.controlling_process(ctx.rtp_socket, state.client_session)
          :ok = :gen_udp.controlling_process(ctx.rtcp_socket, state.client_session)
          :ok = :inet.setopts(ctx.rtp_socket, active: true)
          :ok = :inet.setopts(ctx.rtcp_socket, active: true)
        end)

        {Response.new(200), state}
    end
  end

  @impl true
  def handle_pause(state) do
    {Response.new(501), state}
  end

  @impl true
  def handle_teardown(state) do
    ClientSession.close(state.client_session)
    {Response.new(200), %{state | client_session: nil}}
  end

  @impl true
  def handle_closed_connection(state) do
    Logger.debug("[#{state.path}] Connection closed")

    if state.client_session do
      ClientSession.close(state.client_session)
    end
  end

  defp all_tracks_setup?(tracks, configured_media_context) do
    Enum.all?(tracks, fn track ->
      Enum.any?(configured_media_context, fn {key, _} ->
        String.ends_with?(key, track.control_path)
      end)
    end)
  end
end
