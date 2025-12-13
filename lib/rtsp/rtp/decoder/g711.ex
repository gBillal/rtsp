defmodule RTSP.RTP.Decoder.G711 do
  @moduledoc """
  Module responsible for depayloading G711(PCMA/PCMU) rtp packets.
  """

  @behaviour RTSP.RTP.Decoder

  @impl true
  def init(_opts), do: nil

  @impl true
  def handle_discontinuity(state), do: state

  @impl true
  def handle_packet(packet, state) do
    {:ok, {packet.payload, packet.timestamp, true}, state}
  end
end
