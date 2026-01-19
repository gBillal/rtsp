defmodule RTSP.ConnectionManager do
  @moduledoc false

  require Logger

  alias Membrane.RTSP.Response
  alias RTSP.State

  @content_type_header [{"accept", "application/sdp"}]

  @type t() :: pid()
  @type media_types :: [:video | :audio | :application]
  @type connection_opts :: %{stream_uri: binary(), allowed_media_types: media_types()}
  @type track_transport ::
          {:tcp, :gen_tcp.socket()}
          | {:udp, rtp_port :: :inet.port_number(), rtcp_port :: :inet.port_number()}

  @typep rtsp_method_return :: {:ok, RTSP.State.t()} | {:error, reason :: term()}

  @spec transfer_rtsp_socket_control(Membrane.RTSP.t(), pid()) :: :ok
  def transfer_rtsp_socket_control(rtsp_session, new_controller) do
    Membrane.RTSP.transfer_socket_control(rtsp_session, new_controller)
  end

  @spec establish_connection(State.t()) :: rtsp_method_return()
  def establish_connection(state) do
    with {:ok, state} <- start_rtsp_connection(state),
         {:ok, state} <- get_rtsp_description(state) do
      setup_rtsp_connection(state)
    end
  end

  @spec play(State.t()) :: rtsp_method_return()
  def play(state) do
    Logger.debug("ConnectionManager: Setting RTSP on play mode")

    headers = maybe_build_onvif_replay_headers(state.onvif_replay)

    case Membrane.RTSP.play(state.rtsp_session, headers) do
      {:ok, %{status: 200} = resp} ->
        state = update_keep_alive_interval(state, resp)
        {:ok, %{state | keep_alive_timer: start_keep_alive_timer(state)}}

      error ->
        error
    end
  end

  @spec keep_alive(State.t()) :: State.t()
  def keep_alive(state) do
    Logger.debug("Send GET_PARAMETER to keep session alive")

    case Membrane.RTSP.get_parameter(state.rtsp_session) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, body} ->
        Logger.warning("ConnectionManager: Failed to keep RTSP session alive: #{inspect(body)}")

      {:error, reason} ->
        Logger.warning("ConnectionManager: Failed to keep RTSP session alive: #{inspect(reason)}")
    end

    %{state | keep_alive_timer: start_keep_alive_timer(state)}
  end

  @spec check_recbuf(State.t()) :: State.t()
  def check_recbuf(state) do
    Logger.debug("Check recbuf of socket")
    ref = Process.send_after(self(), :check_recbuf, :timer.seconds(5))

    with {:ok, [recbuf: recbuf]} <- :inet.getopts(state.socket, [:recbuf]) do
      :ok = :inet.setopts(state.socket, buffer: recbuf)
    end

    %{state | check_recbuf_timer: ref}
  end

  @spec clean(State.t()) :: State.t()
  def clean(state) do
    if state.rtsp_session, do: Membrane.RTSP.close(state.rtsp_session)
    if state.keep_alive_timer, do: Process.cancel_timer(state.keep_alive_timer)
    if state.check_recbuf_timer, do: Process.cancel_timer(state.check_recbuf_timer)

    %{state | state: :init, rtsp_session: nil, keep_alive_timer: nil}
  end

  @spec get_server_ip(State.t()) :: :inet.ip_address() | nil
  def get_server_ip(state) do
    socket = Membrane.RTSP.get_socket(state.rtsp_session)

    case :inet.peername(socket) do
      {:ok, {ip, _port}} -> ip
      _other -> nil
    end
  end

  @spec start_rtsp_connection(State.t()) :: rtsp_method_return()
  defp start_rtsp_connection(state) do
    case Membrane.RTSP.start_link(state.stream_uri,
           connection_timeout: state.timeout,
           response_timeout: state.timeout
         ) do
      {:ok, session} ->
        {:ok, %{state | rtsp_session: session}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_rtsp_description(State.t()) :: rtsp_method_return()
  defp get_rtsp_description(%{rtsp_session: rtsp_session} = state, retry \\ true) do
    Logger.debug("ConnectionManager: Getting RTSP description")

    case Membrane.RTSP.describe(rtsp_session, @content_type_header) do
      {:ok, %{status: 200} = response} ->
        tracks = RTSP.Helper.get_tracks(response, state.allowed_media_types)
        {:ok, %{state | tracks: tracks}}

      {:ok, %{status: 401}} ->
        if retry, do: get_rtsp_description(state, false), else: {:error, :unauthorized}

      _result ->
        {:error, :getting_rtsp_description_failed}
    end
  end

  @spec setup_rtsp_connection(State.t()) :: rtsp_method_return()
  defp setup_rtsp_connection(state) do
    case state.transport do
      :tcp ->
        setup_rtsp_connection_with_tcp(state, state.tracks, state.onvif_replay)

      {:udp, min_port, max_port} ->
        setup_rtsp_connection_with_udp(state, min_port, max_port, state.tracks)
    end
  end

  @spec start_keep_alive_timer(State.t()) :: reference()
  defp start_keep_alive_timer(%{keep_alive_interval: interval}) do
    Process.send_after(self(), :keep_alive, interval)
  end

  @spec setup_rtsp_connection_with_tcp(State.t(), [RTSP.track()], boolean()) ::
          {:ok, State.t()} | {:error, reason :: term()}
  defp setup_rtsp_connection_with_tcp(state, tracks, onvif_replay) do
    socket = Membrane.RTSP.get_socket(state.rtsp_session)
    onvif_header = if onvif_replay == [], do: [], else: [{"Require", "onvif-replay"}]

    tracks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state, []}, fn {track, idx}, {:ok, state, tracks} ->
      transport_header =
        [{"Transport", "RTP/AVP/TCP;unicast;interleaved=#{idx * 2}-#{idx * 2 + 1}"}] ++
          onvif_header

      case Membrane.RTSP.setup(state.rtsp_session, track.control_path, transport_header) do
        {:ok, %{status: 200} = resp} ->
          state = update_keep_alive_interval(state, resp)
          {:cont, {:ok, state, [%{track | transport: {:tcp, socket}} | tracks]}}

        error ->
          Logger.debug("ConnectionManager: Setting up RTSP connection failed: #{inspect(error)}")

          {:halt, {:error, :setting_up_rtsp_connection_failed}}
      end
    end)
    |> case do
      {:ok, state, tracks} -> {:ok, %{state | tracks: Enum.reverse(tracks)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec setup_rtsp_connection_with_udp(
          State.t(),
          :inet.port_number(),
          :inet.port_number(),
          [RTSP.track()],
          [RTSP.track()]
        ) :: {:ok, tracks :: [RTSP.track()]} | {:error, reason :: term()}
  defp setup_rtsp_connection_with_udp(
         state,
         port,
         max_port,
         tracks,
         set_up_tracks \\ []
       )

  defp setup_rtsp_connection_with_udp(state, _port, _max_port, [], set_up_tracks) do
    {:ok, %{state | tracks: Enum.reverse(set_up_tracks)}}
  end

  defp setup_rtsp_connection_with_udp(_state, max_port, max_port, _tracks, _set_up_tracks) do
    # when current port is equal to max_port the range is already exceeded, because port + 1 is also required.
    {:error, :port_range_exceeded}
  end

  defp setup_rtsp_connection_with_udp(state, port, max_port, tracks, set_up_tracks) do
    if port_taken?(port) or port_taken?(port + 1) do
      setup_rtsp_connection_with_udp(state, port + 1, max_port, tracks, set_up_tracks)
    else
      transport_header = [{"Transport", "RTP/AVP/UDP;unicast;client_port=#{port}-#{port + 1}"}]
      [track | rest_tracks] = tracks

      case Membrane.RTSP.setup(state.rtsp_session, track.control_path, transport_header) do
        {:ok, %{status: 200} = resp} ->
          state = update_keep_alive_interval(state, resp)
          track = %{track | transport: {:udp, port, port + 1}, server_port: get_server_port(resp)}

          setup_rtsp_connection_with_udp(
            state,
            port + 2,
            max_port,
            rest_tracks,
            [track | set_up_tracks]
          )

        _other ->
          {:error, :setup_failed}
      end
    end
  end

  @spec port_taken?(:inet.port_number()) :: boolean()
  defp port_taken?(port) do
    case :gen_udp.open(port) do
      {:ok, socket} ->
        :inet.close(socket)
        false

      _error ->
        true
    end
  end

  defp maybe_build_onvif_replay_headers([]), do: []

  defp maybe_build_onvif_replay_headers(options) do
    start_date = Calendar.strftime(options[:start_date], "%Y%m%dT%H%M%S.%fZ")
    end_date = options[:end_date] && Calendar.strftime(options[:end_date], "%Y%m%dT%H%M%S.%fZ")

    [
      {"Require", "onvif-replay"},
      {"Range", "clock=#{start_date}-#{end_date}"},
      {"Rate-Control", "no"}
    ]
  end

  defp update_keep_alive_interval(state, resp) do
    timeout =
      case Response.get_header(resp, "Session") do
        {:ok, value} -> String.trim(value) |> String.split(";timeout=", parts: 2) |> Enum.at(1)
        _error -> nil
      end

    with timeout when is_binary(timeout) <- timeout,
         {timeout, _} <- Integer.parse(timeout) do
      %{state | keep_alive_interval: :timer.seconds(div(timeout * 8, 10))}
    else
      _other -> state
    end
  end

  defp get_server_port(resp) do
    regex = ~r/server_port=(\d+)-(\d+)/

    with {:ok, transport} <- Response.get_header(resp, "Transport"),
         [port1, port2] <- Regex.run(regex, transport, capture: :all_but_first) do
      {String.to_integer(port1), String.to_integer(port2)}
    else
      _error -> nil
    end
  end
end
