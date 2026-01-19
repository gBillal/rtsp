defmodule RTSP.Server.InnerHandler do
  @moduledoc false

  use Membrane.RTSP.Server.Handler

  require Logger

  alias Membrane.RTSP.Response
  alias RTSP.UDPReceiver

  @impl true
  def init(config) do
    handler_mod = config[:handler]
    handler_state = handler_mod.init(config[:handler_config])
    %{path: nil, handler: handler_mod, handler_state: handler_state, tracks: nil, receivers: []}
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

    tracks =
      request
      |> RTSP.Helper.get_tracks()
      |> Enum.map(&Map.drop(&1, [:transport, :server_port]))

    case state.handler.handle_record(path, tracks, state.handler_state) do
      {:ok, handler_state} ->
        {Response.new(200), %{state | path: path, handler_state: handler_state, tracks: tracks}}

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

    cond do
      Enum.any?(configured_media_context, &(elem(&1, 1).transport == :TCP)) ->
        Logger.error("[#{state.path}] Publishing with TCP is not supported")
        {Response.new(461), state}

      not all_tracks_setup?(state.tracks, configured_media_context) ->
        Logger.error("[#{state.path}] Not all tracks are setup")
        {Response.new(452), state}

      true ->
        receivers =
          Enum.map(configured_media_context, fn {key, ctx} ->
            track = Enum.find(state.tracks, &String.ends_with?(key, &1.control_path))

            callback = fn
              _control_path, :discontinuity ->
                :ok

              control_path, sample ->
                state.handler.handle_media(control_path, sample, state.handler_state)
            end

            {:ok, pid} =
              UDPReceiver.start_link(
                socket: ctx.rtp_socket,
                rtcp_socket: ctx.rtcp_socket,
                track: track,
                callback: callback
              )

            :ok = :gen_udp.controlling_process(ctx.rtp_socket, pid)
            :ok = :gen_udp.controlling_process(ctx.rtcp_socket, pid)
            :ok = :inet.setopts(ctx.rtp_socket, active: true)
            :ok = :inet.setopts(ctx.rtcp_socket, active: true)

            pid
          end)

        {Response.new(200), %{state | receivers: receivers}}
    end
  end

  defp all_tracks_setup?(tracks, configured_media_context) do
    Enum.all?(tracks, fn track ->
      Enum.any?(configured_media_context, fn {key, _} ->
        String.ends_with?(key, track.control_path)
      end)
    end)
  end

  @impl true
  def handle_pause(state) do
    {Response.new(501), state}
  end

  @impl true
  def handle_teardown(state) do
    Enum.each(state.receivers, &UDPReceiver.stop/1)
    {Response.new(200), %{state | receivers: []}}
  end

  @impl true
  def handle_closed_connection(state) do
    Logger.debug("")
    Enum.each(state.receivers, &UDPReceiver.stop/1)
  end
end
