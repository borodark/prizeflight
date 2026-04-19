defmodule Prizeflight.Ingest do
  @moduledoc """
  Lock-free ingest path. `push/1` is `:atomics.get` + `:ets.insert` — no
  GenServer in the hot path, and the ETS table has `write_concurrency`
  so all 88 schedulers can insert at once with per-scheduler granularity.

  The flusher pool (`Prizeflight.Ingest.BufferSupervisor` →
  `Prizeflight.Ingest.Flusher`) drains each shard's inactive ETS table
  on a timer and calls the configured writer.
  """

  alias Prizeflight.Ingest.Flusher

  @spec push(map(), timeout()) :: :ok
  def push(event, _timeout \\ :infinity) do
    idx = rem(:erlang.system_info(:scheduler_id) - 1, pool_size())
    :ets.insert(Flusher.active_table(idx), {unique_key(), event})
    :ok
  end

  @doc """
  Force every flusher to drain synchronously. Flushers are triggered in
  parallel so total wait is bounded by the slowest flusher's drain, not
  the sum.
  """
  def flush_all do
    tasks =
      for idx <- 0..(pool_size() - 1) do
        Task.async(fn -> :ok = Flusher.flush(idx) end)
      end

    Enum.each(tasks, &Task.await(&1, 60_000))
    :ok
  end

  defp unique_key, do: :erlang.unique_integer([:monotonic, :positive])

  defp pool_size do
    Application.get_env(:prizeflight, Prizeflight.Ingest.BufferSupervisor, [])
    |> Keyword.get(:pool_size, 16)
  end
end
