defmodule RTSP.RTP.Decoder.H264 do
  @moduledoc """
  Depayload and parse H264 NAL units

  This module returns access units as a list of NAL units where each keyframe has parameter sets prepended.
  """

  @behaviour RTSP.RTP.Decoder

  require Logger

  alias MediaCodecs.H264.NALU
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

    update_parameter_sets(List.wrap(sps), List.wrap(pps), %State{})
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
        data = [<<0::1, header.nal_ref_idc::2, type::5>> | data]

        {:ok, {[IO.iodata_to_binary(data)], packet.timestamp, packet.marker},
         %{state | fu_acc: nil}}

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
    {sps, pps, key_frame?, first_vcl_nalu, access_unit} = parse_access_unit(state.access_unit)

    access_unit = Enum.reverse(access_unit)
    state = update_parameter_sets(sps, pps, state)

    {sample, state} =
      cond do
        key_frame? ->
          state = %{state | access_unit: get_parameter_sets(state, first_vcl_nalu) ++ access_unit}
          {convert_to_tuple(state, key_frame?), %{state | seen_key_frame?: true}}

        state.seen_key_frame? ->
          {convert_to_tuple(state, key_frame?), state}

        true ->
          {nil, state}
      end

    {sample, %{state | access_unit: []}}
  end

  defp update_parameter_sets([], [], state), do: state

  defp update_parameter_sets(sps, pps, state) do
    sps = Map.new(sps, &{NALU.SPS.id(&1), &1})

    pps =
      Map.new(pps, fn nalu ->
        pps = NALU.PPS.parse(nalu)
        {pps.pic_parameter_set_id, {pps.seq_parameter_set_id, nalu}}
      end)

    %State{state | sps: Map.merge(state.sps, sps), pps: Map.merge(state.pps, pps)}
  end

  defp get_parameter_sets(state, first_vcl_nalu) do
    pic_parameter_set_id = NALU.Slice.parse(first_vcl_nalu).pic_parameter_set_id
    seq_parameter_set_id = state.pps[pic_parameter_set_id] |> elem(0)

    pps =
      state.pps
      |> Map.values()
      |> Enum.filter(&(elem(&1, 0) == seq_parameter_set_id))
      |> Enum.map(&elem(&1, 1))

    [state.sps[seq_parameter_set_id] | pps]
  end

  defp convert_to_tuple(state, keyframe?) do
    {state.access_unit, state.timestamp, keyframe?}
  end

  defp parse_access_unit(access_unit) do
    Enum.reduce(access_unit, {[], [], false, nil, []}, fn nalu_data,
                                                          {sps, pps, keyframe?, first_vcl_nalu,
                                                           access_unit} ->
      nalu = NALU.parse_header(nalu_data)

      case nalu.type do
        :sps ->
          {[nalu_data | sps], pps, keyframe?, first_vcl_nalu, access_unit}

        :pps ->
          {sps, [nalu_data | pps], keyframe?, first_vcl_nalu, access_unit}

        _type ->
          keyframe? = keyframe? or NALU.keyframe?(nalu)

          first_vcl_nalu =
            if is_nil(first_vcl_nalu) and NALU.vcl?(nalu), do: nalu_data, else: first_vcl_nalu

          {sps, pps, keyframe?, first_vcl_nalu, [nalu_data | access_unit]}
      end
    end)
  end
end
