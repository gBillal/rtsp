defmodule RTSP.RTP.Decoder.Opus do
  @moduledoc """
  Opus RTP decoder.
  """

  @behaviour RTSP.RTP.Decoder

  @impl true
  def init(_opts), do: nil

  @impl true
  def handle_packet(%ExRTP.Packet{} = packet, state) do
    {:ok, {packet.payload, packet.timestamp, true}, state}
  end

  @impl true
  def handle_discontinuity(state), do: state
end
