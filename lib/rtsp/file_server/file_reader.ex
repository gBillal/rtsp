defmodule RTSP.FileServer.FileReader do
  @moduledoc false

  alias __MODULE__.MP4

  @callback init(path :: Path.t()) :: struct()

  @callback medias(struct()) :: %{String.t() => ExSDP.Media.t()}

  @callback next_sample(struct(), String.t()) ::
              {{binary(), non_neg_integer(), non_neg_integer(), boolean()}, struct()}
              | {:eof, struct()}

  defstruct [:mod, :state]

  def init(path) do
    ext = Path.extname(path) |> String.downcase()

    cond do
      ext == ".mp4" and Code.ensure_loaded?(ExMP4) ->
        {:ok, %__MODULE__{mod: MP4, state: MP4.init(path)}}

      true ->
        {:error, :unsupported_file}
    end
  end

  def medias(state) do
    state.mod.medias(state.state)
  end

  def next_sample(state, track_id) do
    {sample, reader_state} = state.mod.next_sample(state.state, track_id)
    {sample, %{state | state: reader_state}}
  end
end
