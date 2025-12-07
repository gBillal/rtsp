defmodule RTSP.RTP.Decoder.AV1.AggregationHeader do
  @moduledoc false

  @type t :: %__MODULE__{
          z: 0 | 1,
          y: 0 | 1,
          w: 0..3,
          n: 0 | 1
        }

  defstruct [:z, :y, :w, :n]

  @compile {:inline, parse: 1}
  @spec parse(binary()) :: {:ok, t(), binary()} | {:error, atom()}
  def parse(<<1::1, _y::1, _w::2, 1::1, _::3, _rest::binary>>) do
    {:error, :invalid_aggregation_header}
  end

  def parse(<<z::1, y::1, w::2, n::1, _::3, rest::binary>>) do
    {:ok, %__MODULE__{z: z, y: y, w: w, n: n}, rest}
  end

  def parse(_data), do: {:error, :invalid_aggregation_header}
end
