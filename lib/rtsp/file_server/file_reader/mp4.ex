if Code.ensure_loaded?(ExMP4) do
  defmodule RTSP.FileServer.FileReader.MP4 do
    @moduledoc false

    @behaviour RTSP.FileServer.FileReader

    alias ExMP4.BitStreamFilter.MP4ToAnnexb

    defstruct [:reader, :tracks, :filters]

    @video_timescale 90_000

    @impl true
    def init(path) do
      reader = ExMP4.Reader.new!(path)

      tracks =
        reader
        |> ExMP4.Reader.tracks()
        |> Map.new(&{"track=#{&1.id}", &1})

      filters =
        Map.new(tracks, fn {control, track} ->
          case track.media do
            codec when codec in [:h264, :h265] ->
              {:ok, filter} = MP4ToAnnexb.init(track, [])
              {control, {MP4ToAnnexb, filter}}

            _ ->
              {control, nil}
          end
        end)

      %__MODULE__{reader: reader, tracks: tracks, filters: filters}
    end

    @impl true
    def medias(state) do
      Map.new(state.tracks, fn {control, track} ->
        {control, track_to_sdp_media(track, control)}
      end)
    end

    @impl true
    def next_sample(state, track_id) do
      track = Map.fetch!(state.tracks, track_id)

      case ExMP4.Track.next_sample(track) do
        :done ->
          {:eof, state}

        {sample_metadata, track} ->
          {sample, state} =
            state.reader
            |> ExMP4.Reader.read_sample(sample_metadata)
            |> filter_sample(track_id, state)

          sample = maybe_convert_timescale(track, sample)
          state = %{state | tracks: Map.put(state.tracks, track_id, track)}
          {{sample.payload, sample.dts, sample.pts, sample.sync?}, state}
      end
    end

    defp track_to_sdp_media(track, control) do
      pt = track.id + 95

      %ExSDP.Media{
        type: track.type,
        port: 0,
        protocol: "RTP/AVP",
        fmt: [pt],
        attributes: [
          {"control", control},
          fmtp(track, pt),
          %ExSDP.Attribute.RTPMapping{
            payload_type: pt,
            encoding: encoding(track.media),
            clock_rate: if(track.type == :video, do: @video_timescale, else: track.timescale),
            params: if(track.media == :aac, do: "2")
          }
        ]
      }
    end

    defp filter_sample(sample, track_id, state) do
      case Map.get(state.filters, track_id) do
        nil ->
          {sample, state}

        {filter_module, filter_state} ->
          {sample, filter_state} = filter_module.filter(filter_state, sample)
          filters = %{state.filters | track_id => {filter_module, filter_state}}
          {sample, %{state | filters: filters}}
      end
    end

    defp maybe_convert_timescale(%{type: :video, timescale: scale}, sample) do
      %{
        sample
        | dts: div(sample.dts * @video_timescale, scale),
          pts: div(sample.pts * @video_timescale, scale)
      }
    end

    defp maybe_convert_timescale(_track, sample), do: sample

    defp encoding(:aac), do: "MPEG4-GENERIC"
    defp encoding(other), do: String.upcase("#{other}")

    defp fmtp(%{media: :h264} = track, pt) do
      sps = List.first(track.priv_data.sps)
      pps = List.first(track.priv_data.pps)

      %ExSDP.Attribute.FMTP{
        pt: pt,
        packetization_mode: 1,
        sprop_parameter_sets: %{sps: sps, pps: pps}
      }
    end

    defp fmtp(%{media: :h265} = track, pt) do
      %ExSDP.Attribute.FMTP{
        pt: pt,
        sprop_vps: track.priv_data.vps,
        sprop_sps: track.priv_data.sps,
        sprop_pps: track.priv_data.pps
      }
    end

    defp fmtp(%{media: :av1}, pt) do
      %ExSDP.Attribute.FMTP{pt: pt}
    end

    defp fmtp(%{media: :aac} = track, pt) do
      [descriptor] = MediaCodecs.MPEG4.parse_descriptors(track.priv_data.es_descriptor)
      asc = descriptor.dec_config_descr.decoder_specific_info

      "fmtp:#{pt} mode=AAC-hbr; sizeLength=13; indexLength=3; indexDeltaLength=3; constantDuration=1024; config=#{Base.encode16(asc, case: :upper)}"
    end

    defp fmtp(track, _pt) do
      raise "Unsupported codec #{track.media} in MP4 track"
    end
  end
end
