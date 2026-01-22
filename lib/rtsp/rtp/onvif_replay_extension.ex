defmodule RTSP.RTP.OnvifReplayExtension do
  @moduledoc """
  A module describing onvif replay rtp header extension
  """

  @ntp_unix_epoch_diff 2_208_988_800
  @second 10 ** 9
  @two_to_pow_32 2 ** 32

  @type t :: %__MODULE__{
          timestamp: non_neg_integer(),
          keyframe?: boolean(),
          discontinuity?: boolean(),
          last_frame?: boolean()
        }

  defstruct [:timestamp, :keyframe?, :discontinuity?, :last_frame?]

  @doc """
  Decodes the rtp onvif extension header.
  """
  @spec decode(header :: binary()) :: t()
  def decode(<<ntp_timestamp::binary-size(8), c::1, _e::1, d::1, t::1, _rest::28>>) do
    %__MODULE__{
      timestamp: from_ntp_timestamp(ntp_timestamp),
      keyframe?: c == 1,
      discontinuity?: d == 1,
      last_frame?: t == 1
    }
  end

  defp from_ntp_timestamp(<<ntp_seconds::32, ntp_fraction::32>>) do
    fractional = div(ntp_fraction * @second, @two_to_pow_32)
    unix_seconds = (ntp_seconds - @ntp_unix_epoch_diff) * @second
    # return timestamp in milliseconds
    div(unix_seconds + fractional, 1000_000)
  end
end
