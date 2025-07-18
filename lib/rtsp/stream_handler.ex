defmodule RTSP.StreamHandler do
  @moduledoc false
  # Handle an RTP stream.

  require Logger

  alias RTSP.RTP.OnvifReplayExtension

  @timestamp_limit Bitwise.bsl(1, 32)
  @seq_number_limit Bitwise.bsl(1, 16)
  @max_replay_timestamp_diff 10

  @type t :: %__MODULE__{
          timestamps: {integer(), integer()} | nil,
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
    wallclock_timestamp: nil,
    clock_rate: 90_000,
    previous_seq_num: nil,
    last_replay_timestamp: ~U(1970-01-01 00:00:00Z)
  ]

  @spec handle_packet(t(), ExRTP.Packet.t(), DateTime.t()) :: {boolean(), tuple() | nil, t()}
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
    rem(handler.previous_seq_num + 1, @seq_number_limit) != seq_num
  end

  @spec convert_timestamp(t(), ExRTP.Packet.t()) :: {t(), ExRTP.Packet.t()}
  defp convert_timestamp(handler, %{timestamp: rtp_timestamp} = packet) do
    {timestamp_base, previous_timestamp} = handler.timestamps || {rtp_timestamp, rtp_timestamp}

    # timestamps in RTP don't have to be monotonic therefore there can be
    # a situation where in 2 consecutive packets the latter packet will have smaller timestamp
    # than the previous one while not overflowing the timestamp number
    # https://datatracker.ietf.org/doc/html/rfc3550#section-5.1

    timestamp_base =
      case from_which_rollover(previous_timestamp, rtp_timestamp, @timestamp_limit) do
        :next -> timestamp_base - @timestamp_limit
        :previous -> timestamp_base + @timestamp_limit
        :current -> timestamp_base
      end

    timestamp = rtp_timestamp - timestamp_base
    {%{handler | timestamps: {timestamp_base, rtp_timestamp}}, %{packet | timestamp: timestamp}}
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

  @spec from_which_rollover(number(), number(), number()) :: :current | :previous | :next
  def from_which_rollover(previous_value, new_value, rollover_length) do
    # a) current rollover
    distance_if_current = abs(previous_value - new_value)
    # b) new_value is from the previous rollover
    distance_if_previous = abs(previous_value - (new_value - rollover_length))
    # c) new_value is in the next rollover
    distance_if_next = abs(previous_value - (new_value + rollover_length))

    [
      {:current, distance_if_current},
      {:previous, distance_if_previous},
      {:next, distance_if_next}
    ]
    |> Enum.min_by(fn {_atom, distance} -> distance end)
    |> then(fn {result, _value} -> result end)
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
