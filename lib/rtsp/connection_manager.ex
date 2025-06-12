defmodule RTSP.ConnectionManager do
  @moduledoc false

  require Logger

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

    headers =
      case state.onvif_replay do
        true ->
          start_date = Calendar.strftime(state.start_date, "%Y%m%dT%H%M%S.%fZ")
          end_date = state.end_date && Calendar.strftime(state.end_date, "%Y%m%dT%H%M%S.%fZ")

          [
            {"Require", "onvif-replay"},
            {"Range", "clock=#{start_date}-#{end_date}"},
            {"Rate-Control", "no"}
          ]

        false ->
          []
      end

    case Membrane.RTSP.play(state.rtsp_session, headers) do
      {:ok, %{status: 200}} ->
        {:ok, %{state | keep_alive_timer: start_keep_alive_timer(state)}}

      error ->
        error
    end
  end

  @spec keep_alive(State.t()) :: State.t()
  def keep_alive(state) do
    Logger.debug("Send GET_PARAMETER to keep session alive")

    {:ok, %{status: 200}} = Membrane.RTSP.get_parameter(state.rtsp_session)

    %{state | keep_alive_timer: start_keep_alive_timer(state)}
  end

  @spec check_recbuf(State.t()) :: State.t()
  def check_recbuf(state) do
    Logger.debug("Check recbuf of socket")
    ref = Process.send_after(self(), :check_recbuf, :timer.seconds(30))

    with {:ok, [recbuf: recbuf]} <- :inet.getopts(state.socket, [:recbuf]) do
      :ok = :inet.setopts(state.socket, buffer: recbuf)
    end

    %{state | check_recbuf_timer: ref}
  end

  @spec clean(State.t()) :: State.t()
  def clean(state) do
    if state.rtsp_session != nil, do: Membrane.RTSP.close(state.rtsp_session)
    if state.keep_alive_timer != nil, do: Process.cancel_timer(state.keep_alive_timer)
    if state.check_recbuf_timer != nil, do: Process.cancel_timer(state.check_recbuf_timer)

    %{state | state: :init, rtsp_session: nil, keep_alive_timer: nil}
  end

  @spec start_rtsp_connection(State.t()) :: rtsp_method_return()
  defp start_rtsp_connection(state) do
    case Membrane.RTSP.start_link(state.stream_uri, response_timeout: state.timeout) do
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
        tracks = get_tracks(response, state.allowed_media_types)
        {:ok, %{state | tracks: tracks}}

      {:ok, %{status: 401}} ->
        if retry, do: get_rtsp_description(state, false), else: {:error, :unauthorized}

      _result ->
        {:error, :getting_rtsp_description_failed}
    end
  end

  @spec setup_rtsp_connection(State.t()) :: rtsp_method_return()
  defp setup_rtsp_connection(%{transport: :tcp} = state) do
    case setup_rtsp_connection_with_tcp(state.rtsp_session, state.tracks, state.onvif_replay) do
      {:ok, tracks} -> {:ok, %{state | tracks: tracks}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp setup_rtsp_connection(%{transport: {:udp, min_port, max_port}} = state) do
    case setup_rtsp_connection_with_udp(state.rtsp_session, min_port, max_port, state.tracks) do
      {:ok, tracks} -> {:ok, %{state | tracks: tracks}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_keep_alive_timer(State.t()) :: reference()
  defp start_keep_alive_timer(%{keep_alive_interval: interval}) do
    Process.send_after(self(), :keep_alive, interval)
  end

  @spec setup_rtsp_connection_with_tcp(Membrane.RTSP.t(), [RTSP.track()], boolean()) ::
          {:ok, tracks :: [RTSP.track()]} | {:error, reason :: term()}
  defp setup_rtsp_connection_with_tcp(rtsp_session, tracks, onvif_replay?) do
    socket = Membrane.RTSP.get_socket(rtsp_session)
    onvif_header = if onvif_replay?, do: [{"Require", "onvif-replay"}], else: []

    tracks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {track, idx}, {:ok, set_up_tracks} ->
      transport_header =
        [{"Transport", "RTP/AVP/TCP;unicast;interleaved=#{idx * 2}-#{idx * 2 + 1}"}] ++
          onvif_header

      case Membrane.RTSP.setup(rtsp_session, track.control_path, transport_header) do
        {:ok, %{status: 200}} ->
          {:cont, {:ok, [%{track | transport: {:tcp, socket}} | set_up_tracks]}}

        error ->
          Logger.debug("ConnectionManager: Setting up RTSP connection failed: #{inspect(error)}")

          {:halt, {:error, :setting_up_rtsp_connection_failed}}
      end
    end)
  end

  @spec setup_rtsp_connection_with_udp(
          Membrane.RTSP.t(),
          :inet.port_number(),
          :inet.port_number(),
          [RTSP.track()],
          [RTSP.track()]
        ) :: {:ok, tracks :: [RTSP.track()]} | {:error, reason :: term()}
  defp setup_rtsp_connection_with_udp(
         rtsp_session,
         port,
         max_port,
         tracks,
         set_up_tracks \\ []
       )

  defp setup_rtsp_connection_with_udp(_rtsp_session, _port, _max_port, [], set_up_tracks) do
    {:ok, Enum.reverse(set_up_tracks)}
  end

  defp setup_rtsp_connection_with_udp(_rtsp_session, max_port, max_port, _tracks, _set_up_tracks) do
    # when current port is equal to max_port the range is already exceeded, because port + 1 is also required.
    {:error, :port_range_exceeded}
  end

  defp setup_rtsp_connection_with_udp(rtsp_session, port, max_port, tracks, set_up_tracks) do
    if port_taken?(port) or port_taken?(port + 1) do
      setup_rtsp_connection_with_udp(rtsp_session, port + 1, max_port, tracks, set_up_tracks)
    else
      transport_header = [{"Transport", "RTP/AVP/UDP;unicast;client_port=#{port}-#{port + 1}"}]
      [track | rest_tracks] = tracks

      case Membrane.RTSP.setup(rtsp_session, track.control_path, transport_header) do
        {:ok, %{status: 200}} ->
          set_up_tracks = [%{track | transport: {:udp, port, port + 1}} | set_up_tracks]

          setup_rtsp_connection_with_udp(
            rtsp_session,
            port + 2,
            max_port,
            rest_tracks,
            set_up_tracks
          )

        _other ->
          {:error, :setup_failed}
      end
    end
  end

  @spec port_taken?(:inet.port_number()) :: boolean()
  defp port_taken?(port) do
    case :gen_udp.open(port, reuseaddr: true) do
      {:ok, socket} ->
        :inet.close(socket)
        false

      _error ->
        true
    end
  end

  @spec get_tracks(Membrane.RTSP.Response.t(), media_types()) :: [RTSP.track()]
  defp get_tracks(%{body: %ExSDP{media: media_list}}, stream_types) do
    media_list
    |> Enum.filter(&(&1.type in stream_types))
    |> Enum.map(fn media ->
      %{
        control_path: get_attribute(media, "control", ""),
        type: media.type,
        rtpmap: get_attribute(media, ExSDP.Attribute.RTPMapping),
        fmtp: get_attribute(media, ExSDP.Attribute.FMTP),
        transport: nil
      }
    end)
  end

  @spec get_attribute(ExSDP.Media.t(), ExSDP.Attribute.key(), default) ::
          ExSDP.Attribute.t() | default
        when default: var
  defp get_attribute(video_attributes, attribute, default \\ nil) do
    case ExSDP.get_attribute(video_attributes, attribute) do
      {^attribute, value} -> value
      %^attribute{} = value -> value
      _other -> default
    end
  end
end
