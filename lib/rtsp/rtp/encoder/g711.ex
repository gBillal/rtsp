defmodule RTSP.RTP.Encoder.G711 do
  @moduledoc """
  Module responsible for payloading G711(PCMA/PCMU) into rtp packets.
  """

  @behaviour RTSP.RTP.Encoder

  @max_rtp_seq_no Bitwise.bsl(1, 16) - 1

  @impl true
  def init(options) do
    %{
      sequence_number: Keyword.get(options, :sequence_number, Enum.random(0..@max_rtp_seq_no//1)),
      payload_type: Keyword.get(options, :payload_type, 0),
      ssrc: Keyword.get(options, :ssrc, 0),
      timestamp: 0
    }
  end

  @impl true
  def handle_sample(data, timestamp, state) do
    packet =
      ExRTP.Packet.new(data,
        payload_type: state.payload_type,
        sequence_number: state.sequence_number,
        timestamp: timestamp,
        ssrc: state.ssrc
      )

    state = %{state | sequence_number: Bitwise.band(state.sequence_number + 1, @max_rtp_seq_no)}
    {[packet], state}
  end
end
