defmodule RTSP.Server.ClientHandler do
  @moduledoc """
  Behaviour defining client handler of an rtsp server.
  """

  @type state :: term()

  @doc """
  Callback invoked to initialize a handler.

  The returned term is passed as
  """
  @callback init(options :: keyword()) :: state()

  @doc """
  Callback invoked to handle a record request. (RTSP ANNOUNCE)

  The first argument is the relative path of the resource to publish, the second
  argument is the list of tracks the user intend to publish and the third is the
  state of the handler.
  """
  @callback handle_record(path :: String.t(), tracks :: [map()], state()) ::
              {:ok, state()} | {:error, any()}

  @doc """
  Callback invoked to handle media samples.
  """
  @callback handle_media(control_path :: String.t(), sample :: tuple(), state()) :: state()

  @doc """
  Callback invoked to handle detected discontinuity in the stream identified by control path.
  """
  @callback handle_discontinuity(control_path :: String.t(), state()) :: state()

  @doc """
  Callback invoked when the connection is closed.
  """
  @callback handle_closed_connection(state) :: :ok

  defmacro __using__(__options) do
    quote do
      @behaviour unquote(__MODULE__)

      require Logger

      @impl true
      def init(options), do: options

      @impl true
      def handle_record(path, tracks, state) do
        Logger.debug("Handle record/publish #{length(tracks)} track(s) to: #{path}")
        {:ok, state}
      end

      @impl true
      def handle_media(control_path, sample, state) do
        Logger.debug("[#{control_path}] New media sample")
        state
      end

      @impl true
      def handle_discontinuity(control_path, state) do
        Logger.debug("[#{control_path}] discontuinty")
        state
      end

      @impl true
      def handle_closed_connection(_state) do
        Logger.debug("Connection closed")
      end

      defoverridable init: 1,
                     handle_record: 3,
                     handle_media: 3,
                     handle_discontinuity: 2,
                     handle_closed_connection: 1
    end
  end
end
