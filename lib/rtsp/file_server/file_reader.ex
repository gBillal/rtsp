defmodule RTSP.FileServer.FileReader do
  @moduledoc false

  @callback init(path :: Path.t()) :: struct()

  @callback medias(struct()) :: %{String.t() => ExSDP.Media.t()}

  @callback next_sample(struct(), String.t()) ::
              {{binary(), non_neg_integer(), non_neg_integer(), boolean()}, struct()}
              | {:eof, struct()}

  defstruct [:mod, :state]

  def init(mod, path) do
    %__MODULE__{mod: mod, state: mod.init(path)}
  end

  def medias(state) do
    state.mod.medias(state.state)
  end

  def next_sample(state, track_id) do
    {sample, reader_state} = state.mod.next_sample(state.state, track_id)
    {sample, %{state | state: reader_state}}
  end
end
