defmodule Pigeon.FCM do
  @moduledoc """
  `Pigeon.Adapter` for Firebase Cloud Messaging (FCM) push notifications.

  ## Getting Started

  ### Create a dispatcher.

    ```
    # lib/your_app/fcm.ex

    defmodule YourApp.FCM do
      use Pigeon.Dispatcher, otp_app: :your_app
    end
    ```

  ### Install and configure Goth.

  Install and configure [`goth`](https://hexdocs.pm/goth/1.4.3/readme.html#installation)
  if you haven't already. `Pigeon.FCM` requires it for token authentication.

  ### Configure your dispatcher.

  Configure your `FCM` dispatcher and start it on application boot.

  ```
  # config.exs

  config :your_app, YourApp.FCM,
    adapter: Pigeon.FCM,
    auth: YourApp.Goth, # Your Goth worker configured in the previous step.
    project_id: "example-project-123"
  ```

  Add it to your supervision tree.

  ```
  defmodule YourApp.Application do
    @moduledoc false

    use Application

    @doc false
    def start(_type, _args) do
      children = [
        {Goth, name: YourApp.Goth},
        YourApp.FCM
      ]
      opts = [strategy: :one_for_one, name: YourApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  ```

  If preferred, you can include your configuration directly.

  ```
  defmodule YourApp.Application do
    @moduledoc false

    use Application

    @doc false
    def start(_type, _args) do
      children = [
        {Goth, name: YourApp.Goth},
        {YourApp.FCM, fcm_opts()}
      ]
      opts = [strategy: :one_for_one, name: YourApp.Supervisor]
      Supervisor.start_link(children, opts)
    end

    defp fcm_opts do
      [
        adapter: Pigeon.FCM,
        auth: YourApp.Goth,
        project_id: "example-project-123"
      ]
    end
  end
  ```

  ### Create a notification.

  ```
  n = Pigeon.FCM.Notification.new({:token, "reg ID"}, %{"body" => "test message"})
  ```

  ### Send the notification.

  On successful response, `:name` will be set to the name returned from the FCM
  API and `:response` will be `:success`. If there was an error, `:error` will
  contain a JSON map of the response and `:response` will be an atomized version
  of the error type.

  ```
  YourApp.FCM.push(n)
  ```

  ## Customizing Goth

  You can use any of the configuration options (e.g. `:source`) for Goth. Check out the
  documentation of [`Goth.start_link/1`](https://hexdocs.pm/goth/Goth.html#start_link/1)
  for more details.
  """

  defstruct config: nil,
            queue: Pigeon.HTTP.RequestQueue.new(),
            socket: nil

  @behaviour Pigeon.Adapter

  import Pigeon.Tasks, only: [process_on_response: 1]

  alias Pigeon.{AdapterHelper, Configurable}
  alias Pigeon.FCM.Error
  alias Pigeon.HTTP.Request

  @impl Pigeon.Adapter
  def init(opts) do
    config = Pigeon.FCM.Config.new(opts)

    Configurable.validate!(config)

    state = %__MODULE__{config: config}

    case AdapterHelper.connect_socket(config) do
      {:ok, socket} ->
        Configurable.schedule_ping(config)
        {:ok, %{state | socket: socket}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl Pigeon.Adapter
  def handle_push(notification, state) do
    AdapterHelper.handle_push(notification, state, &request_path/2)
  end

  @impl Pigeon.Adapter
  def handle_info(:ping, state) do
    AdapterHelper.handle_ping(state)
  end

  def handle_info({:closed, _}, state) do
    AdapterHelper.reconnect_or_exit(state)
  end

  def handle_info(msg, state) do
    Pigeon.HTTP.handle_info(msg, state, &handle_response/1)
  end

  @spec handle_response(Request.t()) :: :ok
  def handle_response(%{body: body, notification: notif}) do
    case Pigeon.json_library().decode(body) do
      {:ok, %{"name" => name}} ->
        notif
        |> Map.put(:name, name)
        |> Map.put(:response, :success)
        |> process_on_response()

      {:ok, %{"error" => error}} ->
        notif
        |> Map.put(:error, error)
        |> Map.put(:response, Error.parse(error))
        |> process_on_response()

      {:error, reason} ->
        notif
        |> Map.put(:error, %{reason: reason, body: body})
        |> Map.put(:response, :invalid_json)
        |> process_on_response()
    end
  end

  defp request_path(config, _notification) do
    {"POST", "/v1/projects/#{config.project_id}/messages:send"}
  end
end
