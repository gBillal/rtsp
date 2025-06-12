defmodule RTSP.State do
  @moduledoc false

  alias RTSP.ConnectionManager

  @type t :: %__MODULE__{
          state: :init | :connected | :playing,
          stream_uri: binary(),
          allowed_media_types: ConnectionManager.media_types(),
          transport: :tcp | {:udp, non_neg_integer(), non_neg_integer()},
          timeout: non_neg_integer(),
          keep_alive_interval: non_neg_integer(),
          tracks: [RTSP.track()],
          rtsp_session: Membrane.RTSP.t() | nil,
          keep_alive_timer: reference() | nil,
          check_recbuf_timer: reference() | nil,
          socket: :inet.socket() | nil,
          onvif_replay: boolean(),
          start_date: DateTime.t(),
          end_date: DateTime.t(),
          parent_pid: pid()
        }

  @enforce_keys [:stream_uri, :allowed_media_types, :timeout, :keep_alive_interval, :parent_pid]
  defstruct @enforce_keys ++
              [
                state: :init,
                socket: nil,
                transport: :tcp,
                tracks: [],
                rtsp_session: nil,
                keep_alive_timer: nil,
                check_recbuf_timer: nil,
                onvif_replay: false,
                start_date: nil,
                end_date: nil
              ]
end
