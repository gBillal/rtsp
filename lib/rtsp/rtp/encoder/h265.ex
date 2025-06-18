defmodule RTSP.RTP.Encoder.H265 do
  @moduledoc """
  Payload H265 access units into RTP packets.
  """

  @behaviour RTSP.RTP.Encoder

  alias RTSP.RTP.Encoder.H26x

  @impl true
  def init(options), do: H26x.init(options, :h265)

  @impl true
  defdelegate handle_sample(au, timestamp, state), to: H26x
end
