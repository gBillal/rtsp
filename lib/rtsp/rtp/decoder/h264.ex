defmodule RTSP.RTP.Decoder.H264 do
  @moduledoc """
  Parse H264 NAL units
  """

  @behaviour RTSP.RTP.Decoder

  require Logger

  alias RTSP.RTP.Decoder.H264.{FU, NAL, StapA}

  defmodule State do
    @moduledoc false

    defstruct sps: %{},
              pps: %{},
              fu_acc: nil,
              seen_key_frame?: false,
              access_unit: [],
              timestamp: nil
  end

  @impl true
  def init(opts) do
    sps = opts[:sps] && maybe_strip_prefix(opts[:sps])
    pps = opts[:pps] && maybe_strip_prefix(opts[:pps])
    %State{sps: List.wrap(sps), pps: List.wrap(pps)}
  end

  @impl true
  def handle_packet(packet, state) do
    with {:ok, nalus, state} <- depayload(packet, state) do
      {sample, state} = parse(nalus, state)
      {:ok, sample, state}
    end
  end

  @impl true
  def handle_discontinuity(%State{} = state) do
    %{state | fu_acc: nil, access_unit: [], timestamp: nil}
  end

  defp maybe_strip_prefix(<<0, 0, 1, nalu::binary>>), do: nalu
  defp maybe_strip_prefix(<<0, 0, 0, 1, nalu::binary>>), do: nalu
  defp maybe_strip_prefix(nalu), do: nalu

  # depayloader
  defp depayload(packet, state) do
    with {:ok, {header, _payload} = nal} <- NAL.Header.parse_unit_header(packet.payload),
         unit_type = NAL.Header.decode_type(header),
         {:ok, nalus, state} <- handle_unit_type(unit_type, nal, packet, state) do
      {:ok, nalus, state}
    else
      {:error, reason} ->
        {:error, reason, %State{state | fu_acc: nil, access_unit: []}}
    end
  end

  defp handle_unit_type(:single_nalu, _nal, packet, state) do
    {:ok, {[packet.payload], packet.timestamp, packet.marker}, state}
  end

  defp handle_unit_type(:fu_a, {header, data}, packet, state) do
    %{sequence_number: seq_num} = packet

    case FU.parse(data, seq_num, map_state_to_fu(state)) do
      {:ok, {data, type}} ->
        data = NAL.Header.add_header(data, 0, header.nal_ref_idc, type)
        {:ok, {[data], packet.timestamp, packet.marker}, %{state | fu_acc: nil}}

      {:incomplete, fu} ->
        {:ok, {[], packet.timestamp, false}, %{state | fu_acc: fu}}

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_unit_type(:stap_a, {_header, data}, packet, state) do
    with {:ok, nalus} <- StapA.parse(data) do
      {:ok, {nalus, packet.timestamp, packet.marker}, state}
    end
  end

  defp map_state_to_fu(%State{fu_acc: %FU{} = fu}), do: fu
  defp map_state_to_fu(_state), do: %FU{}

  # Parser
  defp parse({[], _timestamp, _marker}, state), do: {nil, state}

  defp parse({nalus, timestamp, marker}, state) do
    cond do
      marker ->
        process_au(%{state | access_unit: state.access_unit ++ nalus, timestamp: timestamp})

      timestamp != state.timestamp ->
        {sample, state} = process_au(state)
        {sample, %{state | timestamp: timestamp, access_unit: nalus}}

      true ->
        {nil, %{state | access_unit: state.access_unit ++ nalus}}
    end
  end

  defp process_au(%{access_unit: []} = state), do: {nil, state}

  defp process_au(state) do
    key_frame? = key_frame?(state.access_unit)

    {sample, state} =
      cond do
        key_frame? ->
          state =
            state
            |> get_parameter_sets()
            |> add_parameter_sets()

          {convert_to_tuple(state, key_frame?), %{state | seen_key_frame?: true}}

        state.seen_key_frame? ->
          {convert_to_tuple(state, key_frame?), state}

        true ->
          {nil, state}
      end

    {sample, %{state | access_unit: []}}
  end

  defp get_parameter_sets(%{access_unit: au} = state) do
    Enum.reduce(au, state, fn
      <<_::3, 7::5, _rest::binary>> = sps, state ->
        %{state | sps: Enum.uniq([sps | state.sps])}

      <<_::3, 8::5, _rest::binary>> = pps, state ->
        %{state | pps: Enum.uniq([pps | state.pps])}

      _nalu, state ->
        state
    end)
  end

  defp add_parameter_sets(state) do
    [state.sps, state.pps, state.access_unit]
    |> Enum.concat()
    |> then(&%{state | access_unit: &1})
  end

  defp convert_to_tuple(state, keyframe?) do
    {state.access_unit, state.timestamp, keyframe?}
  end

  defp key_frame?(au) do
    Enum.any?(au, fn
      <<_::3, 5::5, _rest::binary>> -> true
      _nalu -> false
    end)
  end
end
