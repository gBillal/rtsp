defmodule RTSP.RTP.Decoder.AV1 do
  @moduledoc """
  Depacketize rtp packets into OBUs.
  """
  require Logger

  @behaviour RTSP.RTP.Decoder

  alias __MODULE__.AggregationHeader

  @impl true
  def init(_opts) do
    %{obus: [], last_obu: [], last_timestamp: nil, keyframe?: false}
  end

  @impl true
  def handle_packet(%{payload: payload} = packet, state) do
    with {:ok, header, rest} <- AggregationHeader.parse(payload),
         {:ok, obus} <- get_obus(rest, header.w),
         {:ok, last_obu, obus} <- handle_obus(obus, header, state.last_obu) do
      keyframe? =
        if state.obus == [] and state.last_obu == [], do: header.n == 1, else: state.keyframe?

      state = %{state | keyframe?: keyframe?}

      cond do
        packet.marker ->
          tu =
            obus
            |> prepend_obus(state.obus)
            |> Enum.reverse()
            |> Enum.concat()

          {:ok, {tu, packet.timestamp, state.keyframe?}, %{state | obus: [], last_obu: []}}

        packet.timestamp != state.last_timestamp ->
          tu = state.obus |> Enum.reverse() |> Enum.concat()
          state = %{state | obus: [obus], last_obu: last_obu, last_timestamp: packet.timestamp}
          {:ok, {tu, packet.timestamp, state.keyframe?}, state}

        true ->
          state = %{
            state
            | obus: prepend_obus(obus, state.obus),
              last_obu: last_obu,
              last_timestamp: packet.timestamp
          }

          {:ok, nil, state}
      end
    end
  end

  @impl true
  def handle_discontinuity(state) do
    state
  end

  defp get_obus(data, w, acc \\ [])

  defp get_obus(<<>>, _w, acc), do: {:ok, Enum.reverse(acc)}

  defp get_obus(data, 1, acc), do: {:ok, Enum.reverse([data | acc])}

  defp get_obus(data, w, acc) do
    with {:ok, size, rest} <- leb128(data),
         <<obu::binary-size(size), rest::binary>> <- rest do
      get_obus(rest, w - 1, [obu | acc])
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp handle_obus([obu], %{z: 1, y: 1}, last_obu), do: {:ok, [obu | last_obu], []}
  defp handle_obus([obu], %{y: 1}, []), do: {:ok, [obu], []}

  defp handle_obus([obu], %{z: 1}, last_obu) when last_obu != [],
    do: {:ok, [], [obu_to_binary([obu | last_obu])]}

  defp handle_obus([obu], _header, []), do: {:ok, [], [obu]}
  defp handle_obus([_obu], _header, _last_obu), do: {:error, :invalid_packet}

  defp handle_obus([first_obu | obus], header, last_obu) do
    obus =
      case header.z do
        1 -> [obu_to_binary([first_obu | last_obu]) | obus]
        0 -> [first_obu | obus]
      end

    {obus, last_obu} =
      case header.y do
        1 -> Enum.split(obus, -1)
        0 -> {obus, []}
      end

    {:ok, last_obu, obus}
  end

  defp obu_to_binary(obus), do: Enum.reverse(obus) |> IO.iodata_to_binary()

  @compile {:inline, prepend_obus: 2}
  defp prepend_obus([], obus), do: obus
  defp prepend_obus(new, obus), do: [new | obus]

  defp leb128(data, acc \\ 0, idx \\ 0)

  defp leb128(<<>>, _acc, _idx), do: {:error, :invalid_payload}

  defp leb128(<<stop::1, value::7, rest::binary>>, acc, idx) do
    acc = value |> Bitwise.bsl(idx * 7) |> Bitwise.bor(acc)

    case stop do
      0 -> {:ok, acc, rest}
      1 -> leb128(rest, acc, idx + 1)
    end
  end
end
