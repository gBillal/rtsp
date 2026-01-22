defmodule RTSP.StreamHandler do
  @moduledoc false
  # Handle an RTP stream.

  require Logger

  import Bitwise

  alias RTSP.RTP.OnvifReplayExtension

  @timestamp_limit (1 <<< 32) - 1
  @max_delta_timestamp 1 <<< 31
  @seq_number_limit (1 <<< 16) - 1
  @max_replay_timestamp_diff 10

  @type t :: %__MODULE__{
          timestamps: {integer(), integer()} | nil,
          timestamp_offset: integer() | nil,
          clock_rate: pos_integer(),
          parser_mod: module(),
          parser_state: any(),
          wallclock_timestamp: DateTime.t() | nil,
          previous_seq_num: integer() | nil,
          last_replay_timestamp: DateTime.t(),
          control_path: String.t()
        }

  defstruct [
    :parser_mod,
    :parser_state,
    :control_path,
    timestamps: nil,
    timestamp_offset: nil,
    wallclock_timestamp: nil,
    clock_rate: 90_000,
    previous_seq_num: nil,
    last_replay_timestamp: ~U(1970-01-01 00:00:00Z)
  ]

  @spec handle_packet(t(), ExRTP.Packet.t(), non_neg_integer()) :: {boolean(), tuple() | nil, t()}
  def handle_packet(handler, packet, wallclock_timestamp) do
    {discontinuity, handler} =
      if discontinuity?(packet, handler) do
        parser_state = handler.parser_mod.handle_discontinuity(handler.parser_state)
        {true, %{handler | parser_state: parser_state}}
      else
        {false, handler}
      end

    {sample, handler} =
      %{handler | previous_seq_num: packet.sequence_number}
      |> set_wallclock_timestamp(wallclock_timestamp)
      |> set_last_replay_timestamp(packet)
      |> convert_timestamp(packet)
      |> parse(wallclock_timestamp)

    {discontinuity, sample, handler}
  end

  @spec discontinuity?(ExRTP.Packet.t(), t()) :: boolean()
  defp discontinuity?(_rtp_packet, %{previous_seq_num: nil}), do: false

  defp discontinuity?(%{extensions: %OnvifReplayExtension{} = ex}, handler) do
    cond do
      ex.discontinuity? ->
        true

      # Some cameras don't set the discontinuity flag in the extension
      DateTime.diff(ex.timestamp, handler.last_replay_timestamp) >= @max_replay_timestamp_diff ->
        true

      true ->
        false
    end
  end

  defp discontinuity?(%{sequence_number: seq_num}, handler) do
    (handler.previous_seq_num + 1 &&& @seq_number_limit) != seq_num
  end

  @spec convert_timestamp(t(), ExRTP.Packet.t()) :: {t(), ExRTP.Packet.t()}
  defp convert_timestamp(%{timestamps: nil} = handler, %{timestamp: rtp_timestamp} = packet) do
    {%{handler | timestamps: {rtp_timestamp, rtp_timestamp}, timestamp_offset: rtp_timestamp},
     %{packet | timestamp: 0}}
  end

  defp convert_timestamp(handler, %{timestamp: rtp_timestamp} = packet) do
    {base_ts, base_ext} = handler.timestamps

    delta = rtp_timestamp - base_ts

    # Check for forward or backward rollover
    {acc, timestamp} =
      cond do
        delta >= 0 ->
          base_ext = base_ext + delta
          {{rtp_timestamp, base_ext}, base_ext}

        delta < -@max_delta_timestamp ->
          base_ext = base_ext + (delta &&& @timestamp_limit)
          {{rtp_timestamp, base_ext}, base_ext}

        true ->
          {{base_ts, base_ext}, base_ext + delta}
      end

    {%{handler | timestamps: acc}, %{packet | timestamp: timestamp - handler.timestamp_offset}}
  end

  defp parse({handler, packet}, wallclock_timestamp) do
    case handler.parser_mod.handle_packet(packet, handler.parser_state) do
      {:ok, nil, state} ->
        {nil, %{handler | parser_state: state}}

      {:ok, sample, state} ->
        handler = %{handler | parser_state: state, wallclock_timestamp: wallclock_timestamp}
        {map_sample(sample, wallclock_timestamp), handler}

      {:error, reason, state} ->
        log_error(packet, reason)
        {nil, %{handler | parser_state: state}}
    end
  end

  defp set_wallclock_timestamp(%{wallclock_timestamp: nil} = handler, wallclock_timestamp) do
    %{handler | wallclock_timestamp: wallclock_timestamp}
  end

  defp set_wallclock_timestamp(handler, _wallclock_timestamp), do: handler

  defp set_last_replay_timestamp(handler, %{extensions: [%OnvifReplayExtension{} = ex]}) do
    %{handler | last_replay_timestamp: ex.timestamp}
  end

  defp set_last_replay_timestamp(handler, _packet), do: handler

  defp map_sample(samples, wallclock_timestamp) when is_list(samples) do
    Enum.map(samples, &map_sample(&1, wallclock_timestamp))
  end

  defp map_sample(sample, wallclock_timestamp) do
    Tuple.insert_at(sample, 3, wallclock_timestamp)
  end

  defp log_error(_packet, :invalid_first_packet) do
    Logger.warning("Could not depayload rtp packet: Invalid first packet")
  end

  defp log_error(packet, reason) do
    Logger.warning("""
    Could not depayload rtp packet, ignoring...
    Error reason: #{inspect(reason)}
    Packet: #{inspect(packet, limit: :infinity)}
    """)
  end
end
