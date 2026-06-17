defmodule Pigeon.BackoffWorker do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, nil}
  end

  @impl GenServer
  def handle_info({:push, impl, notification, opts}, state) do
    opts = Keyword.merge(opts, impl: impl)

    Pigeon.push(impl, notification, opts)

    {:noreply, state}
  end
end
