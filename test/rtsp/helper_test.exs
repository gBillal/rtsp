defmodule RTSP.HelperTest do
  use ExUnit.Case, async: true

  alias RTSP.RTP.Decoder

  test "h264 parser tolerates a track without an fmtp line (in-band parameter sets)" do
    assert {Decoder.H264, _state} = RTSP.Helper.parser(:h264, nil)
  end

  test "h265 parser tolerates a missing fmtp the same way" do
    assert {Decoder.H265, _state} = RTSP.Helper.parser(:h265, nil)
  end
end
