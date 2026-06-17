defmodule Pigeon.AdapterHelper do
  @moduledoc false

  alias Pigeon.Configurable
  alias Pigeon.HTTP.RequestQueue

  @max_retries 3

  @doc """
  Checks if the socket is open before sending the request.
  If the socket is closed, requeues the notification and attempts to reconnect.
  """
  def handle_push(notification, state, request_fn) do
    %{socket: socket} = state

    Mint.HTTP.open?(socket)
    |> if do
      do_request(notification, state, request_fn)
    else
      requeue_notification(notification)
      reconnect_or_exit(state)
    end
  end

  defp do_request(notification, state, request_fn) do
    %{config: config, queue: queue, socket: socket} = state
    headers = Configurable.push_headers(config, notification, [])
    payload = Configurable.push_payload(config, notification, [])

    {method, path} = request_fn.(config, notification)

    Mint.HTTP.request(socket, method, path, headers, payload)
    |> case do
      {:ok, socket, ref} ->
        new_q = RequestQueue.add(queue, ref, notification)

        state =
          state
          |> Map.put(:socket, socket)
          |> Map.put(:queue, new_q)

        {:noreply, state}

      _ ->
        requeue_notification(notification)

        {:noreply, state}
    end
  end

  def connect_socket(config, retries \\ @max_retries) do
    case Configurable.connect(config) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        if retries > 0 do
          connect_socket(config, retries - 1)
        else
          {:error, reason}
        end
    end
  end

  def requeue_notification(%{__meta__: %{impl: impl}} = notification)
      when is_atom(impl) and not is_nil(impl) do
    opts = notification.__meta__ |> Map.from_struct() |> Map.to_list()

    apply(impl, :push, [
      notification,
      opts
    ])
  end

  def requeue_notification(_notification) do
    :ok
  end

  def reconnect_or_exit(state) do
    %{config: config} = state

    case connect_socket(config) do
      {:ok, socket} ->
        Configurable.schedule_ping(config)
        {:noreply, %{state | socket: socket}}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end
end
