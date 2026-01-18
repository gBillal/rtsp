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
    %{handler: handler_mod, handler_state: handler_state, tracks: nil, receivers: []}
  end

  @impl true
  def handle_open_connection(_socket, state), do: state

  @impl true
  def handle_describe(_request, state) do
    {Response.new(501), state}
  end

  @impl true
  def handle_announce(request, state) do
    tracks =
      request
      |> RTSP.Helper.get_tracks()
      |> Enum.map(&Map.drop(&1, [:transport, :server_port]))

    case state.handler.handle_record(URI.parse(request.path).path, tracks, state.handler_state) do
      {:ok, handler_state} ->
        {Response.new(200), %{state | handler_state: handler_state, tracks: tracks}}

      {:error, reason} ->
        {Response.new(400) |> Response.with_body(reason), state}
    end
  end

  @impl true
  def handle_setup(_request, :record, state) do
    {Response.new(200), state}
  end

  @impl true
  def handle_play(_configured_media_context, state) do
    {Response.new(501), state}
  end

  @impl true
  def handle_record(configured_media_context, state) do
    if Enum.any?(configured_media_context, fn {_, v} -> v.transport == :TCP end) do
      Logger.warning("Publishing with TCP is not supported")
      {Response.new(461), state}
    else
      receivers =
        Enum.map(configured_media_context, fn {key, ctx} ->
          track = Enum.find(state.tracks, &String.ends_with?(key, &1.control_path))

          {:ok, pid} =
            UDPReceiver.start_link(
              socket: ctx.rtp_socket,
              rtcp_socket: ctx.rtcp_socket,
              track: track,
              callback: fn
                _control_path, :discontinuity ->
                  :ok

                control_path, sample ->
                  state.handler.handle_media(control_path, sample, state.handler_state)
              end
            )

          :ok = :gen_udp.controlling_process(ctx.rtp_socket, pid)
          :ok = :gen_udp.controlling_process(ctx.rtcp_socket, pid)
          :ok = :inet.setopts(ctx.rtp_socket, active: true)
          :ok = :inet.setopts(ctx.rtcp_socket, active: true)

          pid
        end)

      {Response.new(200), %{receivers: receivers}}
    end
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
  def handle_closed_connection(state), do: state
end
