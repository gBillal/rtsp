defmodule RTSP.RTP.Decoder.MPEG4Audio do
  @moduledoc """
  Module responsible for depayloading MPEG-4 AAC (hbr/lbr) rtp packets.
  """

  @behaviour RTSP.RTP.Decoder

  @duration 1024

  @impl true
  def init(mode), do: %{mode: mode}

  @impl true
  def handle_discontinuity(state), do: state

  @impl true
  def handle_packet(packet, state) do
    <<au_header_size::16, au_headers::bits-size(au_header_size), au_body::bitstring>> =
      packet.payload

    {frames, _timestamp} =
      state
      |> access_units_length(au_headers)
      |> Stream.transform(au_body, fn au_size, acc ->
        <<au::binary-size(au_size), rest::binary>> = acc
        {[au], rest}
      end)
      |> Enum.reduce({[], packet.timestamp}, fn frame, {frames, timestamp} ->
        {[{frame, timestamp, true} | frames], timestamp + @duration}
      end)

    {:ok, Enum.reverse(frames), state}
  end

  defp access_units_length(state, au_headers) do
    {size_length, index_length} =
      case state.mode do
        :hbr -> {13, 3}
        :lbr -> {6, 2}
      end

    for <<au_size::size(size_length), _::size(index_length) <- au_headers>>, do: au_size
  end
end
