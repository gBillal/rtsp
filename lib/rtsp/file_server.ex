defmodule RTSP.FileServer do
  @moduledoc """
  An RTSP server that serves a media from files.

  ### Supported Files
  The supported file formats are:
  - MP4 files containing H.264, H265 and AAC codecs.
  """

  alias Membrane.RTSP.Server

  @doc """
  Starts an RTSP file server.
  ## Options
  - `files` - a list of file paths to serve. Required.
  - `rate_control` - whether to enable rate control. Default is `true`.
  - other options supported by `Membrane.RTSP.Server.start_link/1`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {handler_options, server_options} = Keyword.split(opts, [:files, :rate_control])

    server_options =
      Keyword.merge(server_options, handler: __MODULE__.Handler, handler_config: handler_options)

    Server.start_link(server_options)
  end

  @doc """
  Returns the port number the server is listening on.
  """
  @spec port_number(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def port_number(server) do
    Server.port_number(server)
  end

  @doc """
  Stops the RTSP file server.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: Server.stop(server)
end
