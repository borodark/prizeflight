defmodule Prizeflight.Ingest.Flusher do
  @moduledoc """
  Owns one ingest shard and periodically drains it to the configured writer.

  Each shard uses **double-buffered ETS tables** (`_a` and `_b`) with an
  `:atomics` pointer selecting the currently-active one. Writers read the
  atomic, insert into the active table. The flusher drains by:

    1. Flipping the atomic (writers will now target the other table).
    2. Briefly yielding / sleeping so any in-flight `:ets.insert` that
       already read the old pointer completes.
    3. Draining the now-inactive table via `tab2list` + `delete_all_objects`
       with no race window, because no new writers target it.

  Writers never coordinate with the flusher — the push path is a single
  `:atomics.get` + `:ets.insert`, both lock-free at scheduler granularity.
  """

  use GenServer

  require Logger

  alias Prizeflight.Prices

  # ---------- Names & atoms ----------

  def name_for(idx), do: :"prizeflight_flusher_#{idx}"
  def table_a(idx), do: :"prizeflight_shard_#{idx}_a"
  def table_b(idx), do: :"prizeflight_shard_#{idx}_b"

  @doc "Returns the ETS table currently accepting writes for the given shard."
  def active_table(idx) do
    ref = :persistent_term.get({__MODULE__, :ref, idx})

    case :atomics.get(ref, 1) do
      0 -> table_a(idx)
      1 -> table_b(idx)
    end
  end

  @doc "Force an immediate synchronous drain. Used by tests/bench."
  def flush(idx, timeout \\ 60_000) do
    GenServer.call(name_for(idx), :flush, timeout)
  end

  def start_link(opts) do
    idx = Keyword.fetch!(opts, :idx)
    GenServer.start_link(__MODULE__, opts, name: name_for(idx))
  end

  # ---------- GenServer callbacks ----------

  @impl true
  def init(opts) do
    idx = Keyword.fetch!(opts, :idx)
    flush_ms = Keyword.get(opts, :flush_ms, 100)

    for table <- [table_a(idx), table_b(idx)] do
      :ets.new(table, [
        :public,
        :named_table,
        :set,
        {:write_concurrency, :auto},
        {:read_concurrency, false}
      ])
    end

    ref = :atomics.new(1, [])
    :atomics.put(ref, 1, 0)
    :persistent_term.put({__MODULE__, :ref, idx}, ref)

    Process.send_after(self(), :tick, flush_ms)
    {:ok, %{idx: idx, ref: ref, flush_ms: flush_ms}}
  end

  @impl true
  def handle_info(:tick, state) do
    drain_and_write(state.idx, state.ref)
    Process.send_after(self(), :tick, state.flush_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    drain_and_write(state.idx, state.ref)
    {:reply, :ok, state}
  end

  # ---------- Drain ----------

  defp drain_and_write(idx, ref) do
    old = :atomics.get(ref, 1)
    new = 1 - old
    :atomics.put(ref, 1, new)

    # Give any writer that already read `old` a moment to finish its
    # `:ets.insert`. One scheduler yield + 1ms is generous — ETS inserts
    # are ns-scale.
    :erlang.yield()
    :timer.sleep(1)

    old_table = if old == 0, do: table_a(idx), else: table_b(idx)

    case :ets.tab2list(old_table) do
      [] ->
        :ok

      objs ->
        :ets.delete_all_objects(old_table)
        events = Enum.map(objs, fn {_key, ev} -> ev end)

        case Prices.insert_many(events) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("flusher #{idx} write failed: #{inspect(reason)}")
        end
    end
  end
end
