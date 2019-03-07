defmodule Plug.TelemetryTest do
  use ExUnit.Case, async: true
  use Plug.Test

  defmodule MyPlug do
    use Plug.Builder

    plug Plug.Telemetry, event_prefix: [:pipeline]

    plug :send_resp, 200

    defp send_resp(conn, status) do
      Plug.Conn.send_resp(conn, status, "Response")
    end
  end

  defmodule MyNoSendPlug do
    use Plug.Builder

    plug Plug.Telemetry, event_prefix: [:nosend, :pipeline]
  end

  defmodule MyCrashingPlug do
    use Plug.Builder

    plug Plug.Telemetry, event_prefix: [:crashing, :pipeline]
    plug :raise_error
    plug :send_resp, 200

    defp raise_error(_conn, _) do
      raise "Crash!"
    end

    defp send_resp(conn, status) do
      Plug.Conn.send_resp(conn, status, "Response")
    end
  end

  setup do
    start_handler_id = {:start, :rand.uniform(100)}
    stop_handler_id = {:stop, :rand.uniform(100)}

    on_exit(fn ->
      :telemetry.detach(start_handler_id)
      :telemetry.detach(stop_handler_id)
    end)

    {:ok, start_handler: start_handler_id, stop_handler: stop_handler_id}
  end

  test "emits an event before the pipeline and before sending the response", %{
    start_handler: start_handler,
    stop_handler: stop_handler
  } do
    attach(start_handler, [:pipeline, :call, :start])
    attach(stop_handler, [:pipeline, :call, :stop])

    MyPlug.call(conn(:get, "/"), [])

    assert_received {:event, [:pipeline, :call, :start], measurements, metadata}
    assert %{} == measurements
    assert map_size(metadata) == 1
    assert %{conn: conn} = metadata

    assert_received {:event, [:pipeline, :call, :stop], measurements, metadata}
    assert %{duration: duration} = measurements
    assert is_integer(duration)
    assert map_size(metadata) == 1
    assert %{conn: conn} = metadata
    assert conn.state == :set
    assert conn.status == 200
  end

  test "doesn't emit a stop event if the response is not sent", %{
    start_handler: start_handler,
    stop_handler: stop_handler
  } do
    attach(start_handler, [:nosend, :pipeline, :call, :start])
    attach(stop_handler, [:nosend, :pipeline, :call, :stop])

    MyNoSendPlug.call(conn(:get, "/"), [])

    assert_received {:event, [:nosend, :pipeline, :call, :start], measurements, metadata}
    assert %{} == measurements
    assert %{conn: conn} = metadata

    refute_received {:event, [:nosend, :pipeline, :call, :stop], _, _}
  end

  test "raises if event prefix is not provided" do
    assert_raise ArgumentError, ~r/^:event_prefix is required$/, fn ->
      Plug.Telemetry.init([])
    end
  end

  test "raises if event prefix is not a list of atoms" do
    assert_raise ArgumentError, ~r/^expected :event_prefix to be a list of atoms, got: 1$/, fn ->
      Plug.Telemetry.init(event_prefix: 1)
    end
  end

  test "doesn't emit a stop event when the pipeline crashes", %{
    start_handler: start_handler,
    stop_handler: stop_handler
  } do
    attach(start_handler, [:crashing, :pipeline, :call, :start])
    attach(stop_handler, [:crashing, :pipeline, :call, :stop])

    assert_raise RuntimeError, fn ->
      MyCrashingPlug.call(conn(:get, "/"), [])
    end

    assert_received {:event, [:crashing, :pipeline, :call, :start], measurements, metadata}
    assert %{} == measurements
    assert %{conn: conn} = metadata

    refute_received {:event, [:crashing, :pipeline, :call, :stop], _, _}
  end

  defp attach(handler_id, event) do
    :telemetry.attach(
      handler_id,
      event,
      fn event, measurements, metadata, _ ->
        send(self(), {:event, event, measurements, metadata})
      end,
      nil
    )
  end
end
