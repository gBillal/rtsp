defmodule RTSP.FileServer do
  @moduledoc """
  An RTSP server that serves a media from files.

  ### Supported Files
  The supported file formats are:
  - MP4 files containing H.264, H265 and AAC codecs.
  """

  use GenServer

  alias Membrane.RTSP.Server

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(opts) do
    {:ok, pid} =
      Server.start_link(
        port: opts[:port],
        handler: __MODULE__.Handler,
        handler_config: opts[:files]
      )

    {:ok, %{server_pid: pid}}
  end
end
