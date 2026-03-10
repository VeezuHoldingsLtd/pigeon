defmodule Pigeon.Dispatcher do
  @moduledoc """
  Dispatcher worker for push notifications.

  If your push workers are relatively static, it is encouraged to follow the adapter
  guides. For other use cases, such as supporting dynamic configurations, dispatchers
  can be started and stopped as needed.

  ## Using Dynamic Dispatchers

  ```
  # FCM as an example, but use the relevant options for your push type.
  opts = [
    adapter: Pigeon.FCM,
    auth: YourApp.Goth,
    project_id: "example-project-123"
  ]

  {:ok, pid} = Pigeon.Dispatcher.start_link(opts)
  notification = Pigeon.FCM.Notification.new({:token, "regid"})

  Pigeon.push(pid, notification)
  ```

  ## Loading Configurations from a Database

  ```
  defmodule YourApp.Application do
    @moduledoc false

    use Application

    @doc false
    def start(_type, _args) do
      children = [
        {Goth, name: YourApp.Goth},
        YourApp.Repo,
        {Registry, keys: :unique, name: Registry.YourApp}
      ] ++ push_workers()
      opts = [strategy: :one_for_one, name: YourApp.Supervisor]
      Supervisor.start_link(children, opts)
    end

    defp push_workers do
      YourApp.Repo.PushApplication
      |> YourApp.Repo.all()
      |> Enum.map(&push_spec/1)
    end

    defp push_spec(%{type: "apns"} = config)
      {Pigeon.Dispatcher, [
        adapter: Pigeon.APNS,
        key: config.key,
        key_identifier: config.key_identifier,
        team_id: config.team_id,
        mode: config.mode,
        name: {:via, Registry, {Registry.YourApp, config.name}}
      ]}
    end

    defp push_spec(%{type: "fcm"} = config) do
      {Pigeon.Dispatcher, [
        adapter: Pigeon.FCM,
        auth: String.to_existing_atom(config.auth),
        name: {:via, Registry, {Registry.YourApp, config.name}},
        project_id: config.project_id
      ]}
    end
  end
  ```

  Once running, you can send to any of these workers by name.

  ```
  Pigeon.push({:via, Registry, {Registry.YourApp, "app1"}}, notification)
  ```
  """

  use Supervisor

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @otp_app opts[:otp_app]
      @retries opts[:retries] || 3

      def child_spec(opts \\ []) do
        config_opts = Application.get_env(@otp_app, __MODULE__, [])

        opts =
          [name: __MODULE__, pool_size: Pigeon.default_pool_size()]
          |> Keyword.merge(config_opts)
          |> Keyword.merge(opts)

        %{
          id: __MODULE__,
          start: {Pigeon.Dispatcher, :start_link, [opts]},
          type: :worker
        }
      end

      @doc """
      Sends a push notification with given options.
      """
      def push(notification, opts \\ []) do
        opts = Keyword.merge(opts, impl: __MODULE__)
        current_try = Keyword.get(opts, :current_try, 0)

        case {current_try, @retries} do
          {max_tries, max_tries} ->
            notification
            |> Map.put(:response, :failed_after_retries)
            |> Pigeon.Tasks.process_on_response()

          {0, _} ->
            opts = Keyword.put(opts, :current_try, 1)

            Pigeon.push(__MODULE__, notification, opts)

          {current_try, retries} when current_try < retries ->
            opts = Keyword.put(opts, :current_try, current_try + 1)

            backoff = backoff(current_try)

            Process.send_after(
              Pigeon.BackoffWorker,
              {:push, __MODULE__, notification, opts},
              backoff
            )

          _ ->
            Pigeon.push(__MODULE__, notification, opts)
        end
      end

      defp backoff(current_try) do
        # Exponential backoff with jitter
        # 1 second base delay
        base_delay = 1000
        exponential_delay = base_delay * :math.pow(2, current_try)
        # Add jitter: random value between 0 and exponential_delay
        jitter = :rand.uniform() * exponential_delay

        trunc(exponential_delay + jitter)
      end
    end
  end

  def start_link(opts) do
    opts[:adapter] || raise "adapter is not specified"
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  def init(opts) do
    opts =
      opts
      |> Keyword.put(:supervisor, opts[:name] || self())
      |> Keyword.delete(:name)

    children =
      for index <- 1..(opts[:pool_size] || Pigeon.default_pool_size()) do
        Supervisor.child_spec({Pigeon.DispatcherWorker, opts}, id: index)
      end

    children = [
      Pigeon.BackoffWorker | children
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
