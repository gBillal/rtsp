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

  @spec sdp_medias(GenServer.server()) :: [ExSDP.Media.t()]
  def sdp_medias(server) do
    GenServer.call(server, :sdp_medias)
  end

  @spec start_streaming(
          GenServer.server(),
          Membrane.RTSP.Server.Handler.configured_media_context()
        ) :: :ok
  def start_streaming(server, media_contexts) do
    GenServer.call(server, {:start_streaming, media_contexts})
  end

  def stop(server) do
    GenServer.call(server, :stop)
  end

  @impl true
  def init(opts) do
    with {:ok, reader} <- FileReader.init(opts[:path]) do
      medias = FileReader.medias(reader)

      tracks =
        Map.new(medias, fn {track_id, sdp_media} ->
          mapping = ExSDP.get_attribute(sdp_media, RTPMapping)
          {track_id, init_payloader(mapping)}
        end)

      {:ok,
       %{
         path: opts[:path],
         rate_control: opts[:rate_control],
         reader: reader,
         sdp_medias: medias,
         tracks: tracks,
         pending_samples: %{},
         start_time: nil,
         timer_ref: nil
       }}
    end
  end

  @impl true
  def handle_call({:start_streaming, media_contexts}, _from, state) do
    {tracks, reader} =
      Enum.reduce(state.tracks, {%{}, state.reader}, fn {track_id, track}, {acc, reader} ->
        media_contexts
        |> Enum.find(fn {id, _context} -> String.ends_with?(id, track_id) end)
        |> case do
          nil ->
            {acc, reader}

          {_, media_ctx} ->
            {sample, reader} = FileReader.next_sample(reader, track_id)
            track = Map.put(track, :sample, sample)
            acc = Map.put(acc, track_id, Map.merge(track, media_ctx))
            {acc, reader}
        end
      end)

    ref =
      if state.rate_control,
        do: Process.send_after(self(), :send_media, 20),
        else: Process.send_after(self(), :send_all_media, 20)

    {:reply, :ok,
     %{
       state
       | tracks: tracks,
         start_time: System.monotonic_time(:millisecond),
         reader: reader,
         timer_ref: ref
     }}
  end

  def handle_call(:sdp_medias, _from, state) do
    {:reply, Map.values(state.sdp_medias), state}
  end

  def handle_call(:stop, _from, state) do
    Logger.info("Stopping media streamer")
    :timer.cancel(state.timer_ref)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(:send_media, state) do
    current_time = System.monotonic_time(:millisecond)
    elapsed_time = current_time - state.start_time

    {state, eof?} =
      Enum.reduce(state.tracks, {state, true}, fn {track_id, ctx}, {state, done} ->
        case ctx.sample do
          :eof ->
            {state, done}

          {payload, dts, pts, _sync?} when div(dts * 1000, ctx.timescale) <= elapsed_time ->
            ctx = encode_and_send(ctx, payload, pts)
            {next_sample, reader} = FileReader.next_sample(state.reader, track_id)

            state = %{
              state
              | reader: reader,
                tracks: Map.put(state.tracks, track_id, %{ctx | sample: next_sample})
            }

            {state, false}

          _ ->
            {state, false}
        end
      end)

    state = %{state | timer_ref: Process.send_after(self(), :send_media, 20)}

    if eof? do
      Logger.info("Reached end of file for all tracks")
      :timer.cancel(state.timer_ref)
      close_sockets(state.tracks)
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:send_all_media, state) do
    do_send_media(state.tracks, state.reader)
    Logger.info("Reached end of file for all tracks")
    close_sockets(state.tracks)
    {:stop, :normal, state}
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

  defp init_payloader(%{encoding: "AV1"} = mapping) do
    %{
      payloader: Encoder.AV1,
      payloader_state: Encoder.AV1.init(payload_type: mapping.payload_type),
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

  defp do_send_media(tracks, _reader) when map_size(tracks) == 0, do: :ok

  defp do_send_media(tracks, reader) do
    {track_id, ctx} =
      Enum.min_by(tracks, fn {_id, ctx} ->
        div(elem(ctx.sample, 1) * 1000, ctx.timescale)
      end)

    ctx = encode_and_send(ctx, elem(ctx.sample, 0), elem(ctx.sample, 2))

    case FileReader.next_sample(reader, track_id) do
      {:eof, _} ->
        flush_packets(ctx)
        do_send_media(Map.delete(tracks, track_id), reader)

      {next_sample, reader} ->
        tracks = Map.put(tracks, track_id, %{ctx | sample: next_sample})
        do_send_media(tracks, reader)
    end
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

  # send any remaining packets in buffers before closing
  defp flush_packets(ctx) do
    if function_exported?(ctx.payloader, :flush, 1) do
      ctx.payloader.flush(ctx.payloader_state)
      |> Stream.map(&%{&1 | ssrc: ctx.ssrc})
      |> Stream.map(&ExRTP.Packet.encode/1)
      |> Enum.to_list()
      |> send_packets(ctx)
    end
  end

  defp send_packets(packets, %{transport: :TCP, tcp_socket: socket} = ctx) do
    packets = Enum.map(packets, &[36, elem(ctx.channels, 0), <<byte_size(&1)::16>>, &1])
    :ok = :gen_tcp.send(socket, packets)
  end

  defp send_packets(packets, %{transport: :UDP} = ctx) do
    Enum.each(packets, fn packet ->
      :gen_udp.send(ctx.rtp_socket, ctx.address, elem(ctx.client_port, 0), packet)
    end)
  end

  defp close_sockets(tracks) do
    Enum.each(tracks, fn {_track_id, ctx} ->
      if ctx.transport == :TCP do
        :gen_tcp.close(ctx.tcp_socket)
      end
    end)
  end
end
