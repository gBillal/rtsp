defmodule RTSP.RTP.Decoder.H265 do
  @moduledoc """
  Parse and assemble H265 NAL units into access units.
  """

  @behaviour RTSP.RTP.Decoder

  alias MediaCodecs.H265.NALU
  alias __MODULE__.{AP, FU, NAL}

  defmodule State do
    @moduledoc false

    defstruct vps: %{},
              sps: %{},
              pps: %{},
              fu_acc: nil,
              sprop_max_don_diff: 0,
              seen_key_frame?: false,
              access_unit: [],
              timestamp: nil
  end

  @impl true
  def init(opts) do
    vps = Keyword.get(opts, :vps, []) |> Enum.map(&maybe_strip_prefix/1)
    sps = Keyword.get(opts, :sps, []) |> Enum.map(&maybe_strip_prefix/1)
    pps = Keyword.get(opts, :pps, []) |> Enum.map(&maybe_strip_prefix/1)

    update_parameter_sets(vps, sps, pps, %State{})
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
    %State{state | fu_acc: nil, access_unit: [], timestamp: nil}
  end

  # depayloader
  defp depayload(packet, state) do
    with {:ok, {header, _payload} = nal} <- NAL.Header.parse_unit_header(packet.payload),
         unit_type = NAL.Header.decode_type(header),
         {:ok, nalus, state} <- handle_unit_type(unit_type, nal, packet, state) do
      {:ok, nalus, state}
    else
      {:error, reason} ->
        {:error, reason, %{state | fu_acc: nil, access_unit: []}}
    end
  end

  defp handle_unit_type(:single_nalu, _nalu, packet, state) do
    {:ok, {[packet.payload], packet.timestamp, packet.marker}, state}
  end

  defp handle_unit_type(:fu, {header, data}, packet, state) do
    %{sequence_number: seq_num} = packet

    case FU.parse(data, seq_num, map_state_to_fu(state)) do
      {:ok, {data, type, _don}} ->
        data =
          NAL.Header.add_header(data, 0, type, header.nuh_layer_id, header.nuh_temporal_id_plus1)

        {:ok, {[data], packet.timestamp, packet.marker}, %State{state | fu_acc: nil}}

      {:incomplete, fu} ->
        {:ok, {[], packet.timestamp, false}, %State{state | fu_acc: fu}}

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_unit_type(:ap, {_header, data}, packet, state) do
    with {:ok, nalus} <- AP.parse(data, state.sprop_max_don_diff > 0) do
      {:ok, {Enum.map(nalus, &elem(&1, 0)), packet.timestamp, packet.marker}, state}
    end
  end

  defp map_state_to_fu(%State{fu_acc: %FU{} = fu}), do: fu
  defp map_state_to_fu(state), do: %FU{donl?: state.sprop_max_don_diff > 0}

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
    {vps, sps, pps, key_frame?, first_vcl_nalu, access_unit} =
      parse_access_unit(state.access_unit)

    access_unit = Enum.reverse(access_unit)
    state = update_parameter_sets(vps, sps, pps, state)

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

  defp update_parameter_sets([], [], [], state), do: state

  defp update_parameter_sets(vps, sps, pps, state) do
    vps = Map.new(vps, &{NALU.VPS.id(&1), &1})
    sps = Map.new(sps, &{NALU.SPS.id(&1), &1})

    pps =
      Map.new(pps, fn nalu ->
        pps = NALU.PPS.parse(nalu)
        {pps.pic_parameter_set_id, {pps.seq_parameter_set_id, nalu}}
      end)

    %State{
      state
      | vps: Map.merge(state.vps, vps),
        sps: Map.merge(state.sps, sps),
        pps: Map.merge(state.pps, pps)
    }
  end

  defp get_parameter_sets(state, first_vcl_nalu) do
    pic_parameter_set_id = NALU.Slice.parse(first_vcl_nalu).pic_parameter_set_id
    seq_parameter_set_id = state.pps[pic_parameter_set_id] |> elem(0)

    sps = state.sps[seq_parameter_set_id]
    vps = state.vps[NALU.SPS.video_parameter_set_id(sps)]

    pps =
      state.pps
      |> Map.values()
      |> Enum.filter(&(elem(&1, 0) == seq_parameter_set_id))
      |> Enum.map(&elem(&1, 1))

    [vps, sps | pps]
  end

  defp maybe_strip_prefix(<<0, 0, 1, nalu::binary>>), do: nalu
  defp maybe_strip_prefix(<<0, 0, 0, 1, nalu::binary>>), do: nalu
  defp maybe_strip_prefix(nalu), do: nalu

  defp convert_to_tuple(state, key_frame?) do
    {state.access_unit, state.timestamp, key_frame?}
  end

  defp parse_access_unit(access_unit) do
    Enum.reduce(access_unit, {[], [], [], false, nil, []}, fn nalu_data,
                                                              {vps, sps, pps, keyframe?,
                                                               first_vcl_nalu, access_unit} ->
      nalu = NALU.parse_header(nalu_data)

      case nalu.type do
        :vps ->
          {[nalu_data | vps], sps, pps, keyframe?, first_vcl_nalu, access_unit}

        :sps ->
          {vps, [nalu_data | sps], pps, keyframe?, first_vcl_nalu, access_unit}

        :pps ->
          {vps, sps, [nalu_data | pps], keyframe?, first_vcl_nalu, access_unit}

        _type ->
          keyframe? = keyframe? or NALU.keyframe?(nalu)

          first_vcl_nalu =
            if is_nil(first_vcl_nalu) and NALU.vcl?(nalu_data),
              do: nalu_data,
              else: first_vcl_nalu

          {vps, sps, pps, keyframe?, first_vcl_nalu, [nalu_data | access_unit]}
      end
    end)
  end
end
