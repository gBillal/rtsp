defmodule RTSP.FileServer.MediaStreamer do
  @moduledoc false
  # Stream media to connected clients

  use GenServer

  require Logger

  alias ExSDP.Attribute.RTPMapping
  alias RTSP.FileServer.FileReader
  alias RTSP.RTP.Encoder

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  def start_streaming(server, media_contexts) do
    GenServer.call(server, {:start_streaming, media_contexts})
  end

  def stop(server) do
    GenServer.call(server, :stop)
  end

  @impl true
  def init(opts) do
    tracks =
      Map.new(opts[:medias], fn {track_id, sdp_media} ->
        mapping = ExSDP.get_attribute(sdp_media, RTPMapping)
        {track_id, init_payloader(mapping)}
      end)

    reader_state = opts[:reader_state]

    {:ok,
     %{
       reader_state: reader_state,
       tracks: tracks,
       start_time: nil,
       pending_samples: %{},
       timer_ref: nil
     }}
  end

  @impl true
  def handle_call({:start_streaming, media_contexts}, _from, state) do
    {:ok, ref} = :timer.send_interval(20, :send_media)

    tracks =
      Enum.reduce(state.tracks, %{}, fn {track_id, track}, acc ->
        media_contexts
        |> Enum.find(fn {id, _context} -> String.ends_with?(id, track_id) end)
        |> case do
          nil -> acc
          {_, media_ctx} -> Map.put(acc, track_id, Map.merge(track, media_ctx))
        end
      end)

    {pendings_samples, reader_state} =
      Enum.reduce(Map.keys(tracks), {%{}, state.reader_state}, fn id,
                                                                  {pendings_samples, reader_state} ->
        {sample, new_state} = FileReader.next_sample(reader_state, id)
        {Map.put(pendings_samples, id, sample), new_state}
      end)

    {:reply, :ok,
     %{
       state
       | tracks: tracks,
         start_time: :erlang.monotonic_time(:millisecond),
         pending_samples: pendings_samples,
         reader_state: reader_state,
         timer_ref: ref
     }}
  end

  def handle_call(:stop, _from, state) do
    Logger.info("Stopping media streamer")
    :timer.cancel(state.timer_ref)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(:send_media, state) do
    current_time = :erlang.monotonic_time(:millisecond)
    elapsed_time = current_time - state.start_time

    {pending_samples, state} =
      Enum.reduce(state.pending_samples, {%{}, state}, fn {track_id, sample},
                                                          {pending_samples, state} ->
        ctx = Map.fetch!(state.tracks, track_id)

        case sample do
          :eof ->
            {pending_samples, state}

          {payload, dts, pts, _sync?} when div(dts * 1000, ctx.timescale) <= elapsed_time ->
            ctx = encode_and_send(ctx, payload, pts)
            {next_sample, reader_state} = FileReader.next_sample(state.reader_state, track_id)

            state = %{
              state
              | reader_state: reader_state,
                tracks: Map.put(state.tracks, track_id, ctx)
            }

            {Map.put(pending_samples, track_id, next_sample), state}

          _ ->
            {Map.put(pending_samples, track_id, sample), state}
        end
      end)

    case map_size(pending_samples) do
      0 ->
        :timer.cancel(state.timer_ref)
        {:stop, :normal, state}

      _ ->
        {:noreply, %{state | pending_samples: pending_samples}}
    end
  end

  defp init_payloader(%{encoding: "H264"} = mapping) do
    %{
      payloader: Encoder.H264,
      payloader_state: Encoder.H264.init(payload_type: mapping.payload_type),
      timescale: mapping.clock_rate
    }
  end

  defp init_payloader(%{encoding: "H265"} = mapping) do
    %{
      payloader: Encoder.H265,
      payloader_state: Encoder.H265.init(payload_type: mapping.payload_type),
      timescale: mapping.clock_rate
    }
  end

  defp init_payloader(%{encoding: "MPEG4-GENERIC"} = mapping) do
    %{
      payloader: Encoder.MPEG4Audio,
      payloader_state: Encoder.MPEG4Audio.init(mode: :hbr, payload_type: mapping.payload_type),
      timescale: mapping.clock_rate
    }
  end

  defp encode_and_send(ctx, payload, pts) do
    {rtp_packets, payload_state} = ctx.payloader.handle_sample(payload, pts, ctx.payloader_state)

    rtp_packets
    |> Stream.map(&%{&1 | ssrc: ctx.ssrc})
    |> Stream.map(&ExRTP.Packet.encode/1)
    |> Enum.to_list()
    |> send_packets(ctx)

    %{ctx | payloader_state: payload_state}
  end

  defp send_packets(packets, %{transport: :TCP, tcp_socket: socket} = ctx) do
    packets = Enum.map(packets, &[36, elem(ctx.channels, 0), <<byte_size(&1)::16>>, &1])
    :gen_tcp.send(socket, packets)
  end

  defp send_packets(packets, %{transport: :UDP} = ctx) do
    Enum.each(packets, fn packet ->
      :gen_udp.send(ctx.rtp_socket, ctx.address, elem(ctx.client_port, 0), packet)
    end)
  end
end
