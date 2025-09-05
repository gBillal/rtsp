defmodule RTSP.State do
  @moduledoc false

  alias RTSP.ConnectionManager

  @type t :: %__MODULE__{
          state: :init | :connected | :playing,
          stream_uri: binary(),
          allowed_media_types: ConnectionManager.media_types(),
          transport: :tcp | {:udp, non_neg_integer(), non_neg_integer()},
          timeout: non_neg_integer(),
          tracks: [RTSP.track()],
          rtsp_session: Membrane.RTSP.t() | nil,
          keep_alive_interval: non_neg_integer(),
          keep_alive_timer: reference() | nil,
          check_recbuf_timer: reference() | nil,
          socket: :inet.socket() | nil,
          tcp_receiver: pid() | nil,
          udp_receivers: [pid()],
          reorder_queue_size: non_neg_integer(),
          onvif_replay: Keyword.t(),
          receiver: pid(),
          name: atom() | pid()
        }

  @enforce_keys [:stream_uri, :allowed_media_types, :timeout, :receiver]
  defstruct @enforce_keys ++
              [
                state: :init,
                socket: nil,
                tcp_receiver: nil,
                udp_receivers: [],
                transport: :tcp,
                tracks: [],
                reorder_queue_size: 0,
                rtsp_session: nil,
                keep_alive_interval: :timer.seconds(30),
                keep_alive_timer: nil,
                check_recbuf_timer: nil,
                onvif_replay: [],
                name: nil
              ]
end
