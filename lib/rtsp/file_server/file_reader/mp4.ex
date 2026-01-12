if Code.ensure_loaded?(ExMP4) do
  defmodule RTSP.FileServer.FileReader.MP4 do
    @moduledoc false

    @behaviour RTSP.FileServer.FileReader

    alias ExMP4.BitStreamFilter.MP4ToAnnexb

    defstruct [:reader, :tracks, :filters]

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
            :h264 ->
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
          sample = ExMP4.Reader.read_sample(state.reader, sample_metadata)

          {sample, filters} =
            case Map.get(state.filters, track_id) do
              nil ->
                {sample, state.filters}

              {filter_module, filter_state} ->
                {sample, filter_state} = filter_module.filter(filter_state, sample)
                {sample, %{state.filters | track_id => {filter_module, filter_state}}}
            end

          state = %{state | tracks: Map.put(state.tracks, track_id, track), filters: filters}
          {{sample.payload, sample.dts, sample.pts, sample.sync?}, state}
      end
    end

    defp track_to_sdp_media(track, control) do
      pt = track.id + 95

      encoding =
        case track.media do
          :aac -> "MPEG4-GENERIC"
          other -> String.upcase("#{other}")
        end

      fmtp =
        case track.media do
          :h264 ->
            sps = List.first(track.priv_data.sps)
            pps = List.first(track.priv_data.pps)

            %ExSDP.Attribute.FMTP{
              pt: pt,
              packetization_mode: 1,
              sprop_parameter_sets: %{sps: sps, pps: pps}
            }

          :aac ->
            [descriptor] = MediaCodecs.MPEG4.parse_descriptors(track.priv_data.es_descriptor)
            asc = descriptor.dec_config_descr.decoder_specific_info

            "fmtp:#{pt} mode=AAC-hbr; sizeLength=13; indexLength=3; indexDeltaLength=3; constantDuration=1024; config=#{Base.encode16(asc, case: :upper)}"

          codec ->
            raise "Unsupported codec #{inspect(codec)} in MP4 track"
        end

      %ExSDP.Media{
        type: track.type,
        port: 0,
        protocol: "RTP/AVP",
        fmt: [pt],
        attributes: [
          {"control", control},
          fmtp,
          %ExSDP.Attribute.RTPMapping{
            payload_type: pt,
            encoding: encoding,
            clock_rate: track.timescale,
            params: if(track.media == :aac, do: "2")
          }
        ]
      }
    end
  end
end
