defmodule RTSP.RTP.Encoder.MPEG4Audio do
  @moduledoc """
  Payload AAC frames into RTP packets.

  The encoder does not support interleaving of samples and does not support fragmentation.

  The following options can be provided:
  - `:mode` - either `:hbr` (high bitrate) or `:lbr` (low bitrate).
  - `:sequence_number` - initial sequence number (default is a random number).
  - `:max_payload_size` - maximum size of the RTP payload (default is 1450 bytes).
  - `:payload_type` - RTP payload type (default is 0).
  - `:ssrc` - synchronization source identifier (default is 0).
  """

  @behaviour RTSP.RTP.Encoder

  import Bitwise

  @max_rtp_seq_no (1 <<< 16) - 1
  @max_payload_size 1450

  @impl true
  def init(options) do
    {size_length, index_length} =
      case options[:mode] do
        :hbr -> {13, 3}
        :lbr -> {6, 2}
      end

    %{
      sequence_number: Keyword.get(options, :sequence_number, Enum.random(0..@max_rtp_seq_no)),
      max_payload_size: Keyword.get(options, :max_payload_size, @max_payload_size),
      payload_type: Keyword.get(options, :payload_type, 0),
      ssrc: Keyword.get(options, :ssrc, 0),
      mode: options[:mode],
      size_length: size_length,
      index_length: index_length,
      acc: [],
      acc_size: 0,
      timestamp: 0
    }
  end

  @impl true
  def handle_sample(sample, _rtp_timestamp, state)
      when byte_size(sample) > state.max_payload_size do
    raise "Encoder does not support fragmentation: sample size #{byte_size(sample)} exceeds maximum payload size #{state.max_payload_size}"
  end

  @impl true
  def handle_sample(sample, rtp_timestamp, state)
      when byte_size(sample) + state.acc_size <= state.max_payload_size do
    state =
      case [sample | state.acc] do
        [sample] ->
          %{state | acc: [sample], acc_size: byte_size(sample), timestamp: rtp_timestamp}

        acc ->
          %{state | acc: acc, acc_size: byte_size(sample) + state.acc_size}
      end

    {[], state}
  end

  @impl true
  def handle_sample(sample, rtp_timestamp, state) do
    packet = build_packet(state)

    state = %{
      state
      | acc: [sample],
        acc_size: byte_size(sample),
        timestamp: rtp_timestamp,
        sequence_number: state.sequence_number + 1 &&& @max_rtp_seq_no
    }

    {[packet], state}
  end

  @impl true
  def flush(%{acc: []}), do: []

  @impl true
  def flush(state), do: [build_packet(state)]

  defp build_packet(state) do
    acc = Enum.reverse(state.acc)

    headers =
      Enum.map_join(
        acc,
        &<<byte_size(&1)::size(state.size_length), 0::size(state.index_length)>>
      )

    payload = IO.iodata_to_binary([<<bit_size(headers)::16>>, headers, acc])

    ExRTP.Packet.new(payload,
      timestamp: state.timestamp,
      payload_type: state.payload_type,
      sequence_number: state.sequence_number,
      ssrc: state.ssrc,
      marker: true
    )
  end
end
