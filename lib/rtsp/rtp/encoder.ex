defmodule RTSP.RTP.Encoder do
  @moduledoc """
  Behaviour to payload data into rtp packets.
  """

  @type state :: %{required(:sequence_number) => non_neg_integer(), atom() => any()}
  @type init_opts :: [
          {:sequence_number, non_neg_integer()}
          | {:max_payload_size, non_neg_integer()}
          | {atom(), any()}
        ]

  @type rtp_timestamp :: non_neg_integer()
  @type sample :: binary()

  @doc """
  Initialize deapyloader
  """
  @callback init(init_opts()) :: state()

  @doc """
  Invoked to handle a new sample (e.g. access unit in case of video)
  """
  @callback handle_sample(sample(), rtp_timestamp(), state()) :: {[ExRTP.Packet.t()], state()}
end
