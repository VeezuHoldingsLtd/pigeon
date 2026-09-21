defmodule Pigeon.FCMTest do
  use ExUnit.Case
  doctest Pigeon.FCM, import: true
  doctest Pigeon.FCM.Config, import: true
  doctest Pigeon.FCM.Notification, import: true

  alias Pigeon.FCM.Notification

  @data %{"message" => "Test push"}
  @invalid_project_msg ~r/^attempted to start without valid :project_id/
  @invalid_auth_msg ~r/^attempted to start without valid :auth module/

  defp valid_fcm_reg_id do
    Application.get_env(:pigeon, :test)[:valid_fcm_reg_id]
  end

  describe "init/1" do
    test "raises if configured with invalid project" do
      assert_raise(Pigeon.ConfigError, @invalid_project_msg, fn ->
        [project_id: nil, auth: PigeonTest.Goth]
        |> Pigeon.FCM.init()
      end)
    end

    test "raises if configured with invalid auth module" do
      assert_raise(Pigeon.ConfigError, @invalid_auth_msg, fn ->
        [project_id: "example", auth: nil]
        |> Pigeon.FCM.init()
      end)
    end

    test "starts without a reachable server and fails pushes fast" do
      {:ok, dispatcher} =
        Pigeon.Dispatcher.start_link(
          adapter: Pigeon.FCM,
          auth: PigeonTest.Goth,
          project_id: "example",
          uri: "localhost",
          port: PigeonTest.Server.closed_port()
        )

      n = Notification.new({:token, "bad_reg_id"}, %{}, @data)
      pid = self()
      Pigeon.push(dispatcher, n, on_response: fn x -> send(pid, x) end)

      assert_receive %Notification{response: :not_connected}, 1_000
    end
  end

  describe "handle_response/1" do
    test "returns :success for a JSON response containing a name" do
      body = ~s({"name": "projects/example/messages/123"})
      pid = self()
      request = response_request(body, pid)

      Pigeon.FCM.handle_response(request)

      assert_receive %Notification{response: :success} = response
      assert response.name == "projects/example/messages/123"
    end

    test "returns :invalid_json when the response body is not JSON" do
      body = "<html><body>502 Bad Gateway</body></html>"
      pid = self()
      request = response_request(body, pid)

      Pigeon.FCM.handle_response(request)

      assert_receive %Notification{response: :invalid_json} = response
      assert response.error.body == body
      assert response.error.reason
    end
  end

  describe "handle_push/3" do
    test "successfully sends a valid push" do
      notification =
        {:token, valid_fcm_reg_id()}
        |> Notification.new(%{}, @data)
        |> PigeonTest.FCM.push()

      assert notification.name
    end

    test "successfully sends a valid push with callback" do
      target = {:token, valid_fcm_reg_id()}
      n = Notification.new(target, %{}, @data)
      pid = self()
      PigeonTest.FCM.push(n, on_response: fn x -> send(pid, x) end)

      assert_receive(n = %Notification{target: ^target}, 5000)
      assert n.name
      assert n.response == :success
    end

    @tag :focus
    test "successfully sends a valid push with a dynamic dispatcher" do
      target = {:token, valid_fcm_reg_id()}
      n = Notification.new(target, %{}, @data)
      pid = self()

      {:ok, dispatcher} =
        Pigeon.Dispatcher.start_link(
          Application.get_env(:pigeon, PigeonTest.FCM)
        )

      Pigeon.push(dispatcher, n, on_response: fn x -> send(pid, x) end)

      assert_receive(n = %Notification{target: ^target}, 5000)
      assert n.name
      assert n.response == :success
    end

    test "returns an error on pushing with a bad registration_id" do
      target = {:token, "bad_reg_id"}
      n = Notification.new(target, %{}, @data)
      pid = self()
      PigeonTest.FCM.push(n, on_response: fn x -> send(pid, x) end)

      assert_receive(n = %Notification{target: ^target}, 5000)
      assert n.error
      refute n.name
      assert n.response == :invalid_argument
    end

    test "responds :not_started if dispatcher not started" do
      target = {:token, valid_fcm_reg_id()}
      n = Notification.new(target, %{}, @data)
      pid = self()

      Pigeon.push(PigeonTest.NotStarted, n,
        on_response: fn x -> send(pid, x) end
      )

      assert_receive(n = %Notification{target: ^target}, 5000)
      refute n.name
      assert n.response == :not_started
    end
  end

  defp response_request(body, pid) do
    notification = Notification.new({:token, "bad_reg_id"}, %{}, @data)

    notification = %{
      notification
      | __meta__: %{
          notification.__meta__
          | on_response: fn n -> send(pid, n) end
        }
    }

    %Pigeon.HTTP.Request{body: body, notification: notification}
  end
end
