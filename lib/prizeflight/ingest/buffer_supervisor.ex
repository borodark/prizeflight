defmodule Prizeflight.Ingest.BufferSupervisor do
  @moduledoc """
  Supervises the fixed pool of `Prizeflight.Ingest.Flusher` processes.
  Each flusher owns one ETS shard table.

  Pool size and flush interval come from application env:

      config :prizeflight, Prizeflight.Ingest.BufferSupervisor,
        pool_size: 16,
        flush_ms: 100
  """

  use Supervisor

  alias Prizeflight.Ingest.Flusher

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    cfg = Application.get_env(:prizeflight, __MODULE__, [])
    pool_size = Keyword.get(cfg, :pool_size, 16)
    flush_ms = Keyword.get(cfg, :flush_ms, 100)

    children =
      for idx <- 0..(pool_size - 1) do
        Supervisor.child_spec(
          {Flusher, [idx: idx, flush_ms: flush_ms]},
          id: {Flusher, idx}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
