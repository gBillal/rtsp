defmodule RTSP.RTP.Decoder do
  @moduledoc """
  Behaviour to depayload and parse rtp packets.
  """

  @type state :: any()
  @type rtp_timestamp :: non_neg_integer()
  @type sample :: {binary(), rtp_timestamp(), keyframe? :: boolean()}

  @doc """
  Initialize deapyloader
  """
  @callback init(Keyword.t()) :: state()

  @doc """
  Invoked when a new RTP packet is received
  """
  @callback handle_packet(ExRTP.Packet.t(), state()) :: {:ok, sample(), state()} | {:error, any()}

  @doc """
  Invoked when a discontinuity occurred.

  A discontinuity occurs when an RTP packet is lost or missing by
  examining the sequence numbers.
  """
  @callback handle_discontinuity(state()) :: state()
end
