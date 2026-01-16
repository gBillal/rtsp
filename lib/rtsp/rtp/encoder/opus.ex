defmodule RTSP.RTP.Encoder.Opus do
  @moduledoc """
  Opus RTP encoder.
  """

  @behaviour RTSP.RTP.Encoder

  import Bitwise

  @max_rtp_seq_no (1 <<< 16) - 1

  @impl true
  def init(options) do
    %{
      sequence_number: Keyword.get(options, :sequence_number, Enum.random(0..@max_rtp_seq_no)),
      payload_type: Keyword.get(options, :payload_type, 0),
      ssrc: Keyword.get(options, :ssrc, 0)
    }
  end

  @impl true
  def handle_sample(payload, timestamp, state) do
    packet =
      ExRTP.Packet.new(payload,
        sequence_number: state.sequence_number,
        timestamp: timestamp,
        payload_type: state.payload_type,
        ssrc: state.ssrc
      )

    state = %{state | sequence_number: state.sequence_number + 1 &&& @max_rtp_seq_no}
    {[packet], state}
  end
end
