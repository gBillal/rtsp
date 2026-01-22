defmodule RTSP.UDPReceiver do
  @moduledoc false

  require Logger

  alias RTSP.RTPReceiver

  use GenServer

  @buffer_size 2_000_000

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
    {:udp, rtp_port, rtcp_port} = track[:transport]

    {:ok, socket} = :gen_udp.open(rtp_port, [:binary, active: true])
    {:ok, rtcp_socket} = :gen_udp.open(rtcp_port, [:binary, active: true])
    :ok = :inet.setopts(socket, buffer: @buffer_size, recbuf: @buffer_size)

    state = %{
      socket: socket,
      parser:
        RTPReceiver.UDP.new(socket, rtcp_socket, track,
          reorder_queue_size: options[:reorder_queue_size] || 64
        ),
      receiver: options[:receiver],
      parent_pid: options[:parent_pid]
    }

    send_empty_packets(socket, rtcp_socket, options[:server_ip], track.server_port)

    {:ok, state}
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, data}, %{socket: socket} = state) do
    {events, parser} = RTPReceiver.UDP.process(data, state.parser)

    Enum.each(events, fn
      {:discontinuity, _control_path} ->
        send(state.receiver, {:rtsp, state.parent_pid, :discontinuity})

      {control_path, sample} ->
        send(state.receiver, {:rtsp, state.parent_pid, {control_path, sample}})
    end)

    {:noreply, %{state | parser: parser}}
  end

  @impl true
  def handle_info({:udp, _socket, _ip, _port, _data}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:udp_error, _socket, reason}, state) do
    Logger.error("[UDPReceiver] UDP error: #{inspect(reason)}")
    RTPReceiver.UDP.close(state.parser)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    RTPReceiver.UDP.close(state.parser)
    :ok
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
