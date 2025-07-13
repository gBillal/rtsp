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
            receiver: pid(),
            parent_pid: pid(),
            socket: :inet.socket(),
            rtcp_socket: :inet.socket(),
            track: RTSP.track(),
            packet_reorderer: PacketReorderer.t(),
            stream_handler: RTSP.StreamHandler.t() | nil
          }

    defstruct receiver: nil,
              parent_pid: nil,
              socket: nil,
              rtcp_socket: nil,
              track: nil,
              stream_handler: nil,
              packet_reorderer: PacketReorderer.new()
  end

  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @impl true
  def init(options) do
    track = options[:track]
    {:udp, rtp_port, rtcp_port} = track.transport

    {:ok, socket} = :gen_udp.open(rtp_port, [:binary, active: true, reuseaddr: true])
    {:ok, rtcp_socket} = :gen_udp.open(rtcp_port, [:binary, active: true, reuseaddr: true])

    :ok = :inet.setopts(socket, buffer: @buffer_size, recbuf: @buffer_size)

    encoding = String.to_atom(track.rtpmap.encoding)
    {parser_mod, parser_state} = parser(encoding, track.fmtp)

    stream_handler = %StreamHandler{
      clock_rate: track.rtpmap.clock_rate,
      parser_mod: parser_mod,
      parser_state: parser_state,
      control_path: track.control_path
    }

    state = %State{socket: socket, rtcp_socket: rtcp_socket, stream_handler: stream_handler}
    {:ok, struct!(state, options)}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    :gen_udp.close(state.socket)
    :gen_udp.close(state.rtcp_socket)

    {:stop, :normal, :ok, state}
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
    datetime = DateTime.utc_now()

    {packets, packet_reorderer} =
      packet
      |> decode_rtp!()
      |> PacketReorderer.process(receiver.packet_reorderer)

    handler =
      Enum.reduce(packets, receiver.stream_handler, fn rtp_packet, handler ->
        {discontinuity?, sample, handler} =
          StreamHandler.handle_packet(handler, rtp_packet, datetime)

        if discontinuity? do
          send(receiver.receiver, {:rtsp, receiver.parent_pid, :discontinuity})
        end

        if sample do
          send(
            receiver.receiver,
            {:rtsp, receiver.parent_pid, {handler.control_path, sample}}
          )
        end

        handler
      end)

    %{receiver | stream_handler: handler, packet_reorderer: packet_reorderer}
  end
end
