defmodule RTSP.UDPReceiver do
  @moduledoc false

  require Logger

  import RTSP.Helper

  alias RTSP.RTP.PacketReorderer
  alias RTSP.StreamHandler

  use GenServer

  @buffer_size 2_000_000

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            socket: :inet.socket(),
            rtcp_socket: :inet.socket(),
            track: RTSP.track(),
            packet_reorderer: PacketReorderer.t(),
            stream_handler: RTSP.StreamHandler.t() | nil,
            callback: (String.t(), tuple() | :discontinuity -> :ok)
          }

    @enforce_keys [:packet_reorderer]
    defstruct @enforce_keys ++ [:socket, :rtcp_socket, :track, :stream_handler, :callback]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  end

  @impl true
  def init(options) do
    track = options[:track]

    # check if the sockets already open
    {socket, rtcp_socket, probe?} =
      case track[:transport] do
        {:udp, rtp_port, rtcp_port} ->
          {:ok, socket} = :gen_udp.open(rtp_port, [:binary, active: true])
          {:ok, rtcp_socket} = :gen_udp.open(rtcp_port, [:binary, active: true])
          {socket, rtcp_socket, true}

        _ ->
          {options[:socket], options[:rtcp_socket], false}
      end

    :ok = :inet.setopts(socket, buffer: @buffer_size, recbuf: @buffer_size)

    encoding = track.rtpmap.encoding |> String.downcase() |> String.to_atom()
    {parser_mod, parser_state} = parser(encoding, track.fmtp)

    stream_handler = %StreamHandler{
      clock_rate: track.rtpmap.clock_rate,
      parser_mod: parser_mod,
      parser_state: parser_state,
      control_path: track.control_path
    }

    state = %State{
      socket: socket,
      rtcp_socket: rtcp_socket,
      stream_handler: stream_handler,
      packet_reorderer: PacketReorderer.new(options[:reorder_queue_size] || 64),
      track: track,
      callback: options[:callback] || fn _, _ -> :ok end
    }

    if probe? do
      send_empty_packets(socket, rtcp_socket, options[:server_ip], track.server_port)
    end

    {:ok, state}
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, data}, %State{socket: socket} = state) do
    {:noreply, handle_data(state, data)}
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, _data}, %State{rtcp_socket: socket} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:udp_error, socket, reason}, %State{socket: socket} = state) do
    Logger.error("[UDPReceiver] UDP error: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ok = :gen_udp.close(state.socket)
    :ok = :gen_udp.close(state.rtcp_socket)
  end

  defp handle_data(receiver, packet) do
    datetime = System.os_time(:millisecond)

    {packets, packet_reorderer} =
      packet
      |> decode_rtp!()
      |> PacketReorderer.process(receiver.packet_reorderer)

    handler =
      Enum.reduce(packets, receiver.stream_handler, fn rtp_packet, handler ->
        {discontinuity?, sample, handler} =
          StreamHandler.handle_packet(handler, rtp_packet, datetime)

        if discontinuity?, do: receiver.callback.(handler.control_path, :discontinuity)
        if sample, do: receiver.callback.(handler.control_path, sample)

        handler
      end)

    %{receiver | stream_handler: handler, packet_reorderer: packet_reorderer}
  end

  defp send_empty_packets(_rtp_socket, _rtcp_socket, ip, server_port)
       when is_nil(ip) or is_nil(server_port),
       do: :ok

  defp send_empty_packets(rtp_socket, rtcp_socket, server_ip, {rtp_port, rtcp_port}) do
    rtp_data = ExRTP.Packet.new(<<>>) |> ExRTP.Packet.encode()
    rtcp_data = %ExRTCP.Packet.ReceiverReport{ssrc: 0} |> ExRTCP.Packet.encode()

    :gen_udp.send(rtp_socket, server_ip, rtp_port, rtp_data)
    :gen_udp.send(rtcp_socket, server_ip, rtcp_port, rtcp_data)
  end
end
