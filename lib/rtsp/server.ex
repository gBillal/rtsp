defmodule RTSP.Server do
  @moduledoc """
  """

  alias Membrane.RTSP.Server

  @doc """
  Start an instance of the RTSP server.

  For options see `start_link/1`
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    Server.start(get_config(opts))
  end

  @doc """
  Start and link an instance of the RTSP server.

  The options are the same as `Membrane.RTSP.Server.start_link/1` except that `handler`
  is implementation of `RTSP.Server.ClientHandler`

  > #### `Only Publishing` {: .warning}
  >
  > The started rtsp server only support publishig, not playing (which is planned for a future release)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Server.start_link(get_config(opts))
  end

  defdelegate port_number(port), to: Server

  defdelegate stop(server, opts \\ []), to: Server

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  defp get_config(opts) do
    {handler_opts, opts} = Keyword.split(opts, [:handler, :handler_config])
    Keyword.merge(opts, handler: __MODULE__.InnerHandler, handler_config: handler_opts)
  end
end
