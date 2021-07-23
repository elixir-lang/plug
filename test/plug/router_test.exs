defmodule Plug.RouterTest do
  defmodule Forward do
    use Plug.Router
    use Plug.ErrorHandler

    plug :match
    plug :dispatch

    def call(conn, opts) do
      super(conn, opts)
    after
      Process.put(:plug_forward_call, true)
    end

    get "/" do
      resp(conn, 200, "forwarded")
    end

    get "/script_name" do
      resp(conn, 200, Enum.join(conn.script_name, ","))
    end

    match "/params" do
      resp(conn, 200, conn.params["param"])
    end

    match "/throw", via: [:get, :post] do
      _ = conn
      throw(:oops)
    end

    match "/raise" do
      _ = conn
      raise Plug.Parsers.RequestTooLargeError
    end

    match "/send_and_exit" do
      send_resp(conn, 200, "ok")
      exit(:oops)
    end

    match "/fancy_id/:id" do
      send_resp(conn, 200, id <> "--" <> List.last(conn.path_info))
    end

    def handle_errors(conn, assigns) do
      # Custom call is always invoked before
      true = Process.get(:plug_forward_call)

      Process.put(:plug_handle_errors, Map.put(assigns, :status, conn.status))
      super(conn, assigns)
    end
  end

  defmodule Reforward do
    use Plug.Router
    use Plug.ErrorHandler

    plug :match
    plug :dispatch

    forward "/step2", to: Forward
  end

  defmodule SamplePlug do
    import Plug.Conn

    def init(:hello), do: :world
    def init(options), do: options

    def call(conn, options) do
      send_resp(conn, 200, "#{inspect(options)}")
    end
  end

  defmodule Sample do
    use Plug.Router
    use Plug.ErrorHandler

    plug :match
    plug :verify_router_options
    plug :dispatch

    get "/", host: "foo.bar", do: resp(conn, 200, "foo.bar root")
    get "/", host: "foo.", do: resp(conn, 200, "foo.* root")
    forward "/", to: Forward, host: "foo."

    get "/" do
      resp(conn, 200, "root")
    end

    get "/1/bar" do
      resp(conn, 200, "ok")
    end

    get "/2/:bar" do
      resp(conn, 200, inspect(bar))
    end

    get "/3/bar-:bar" do
      resp(conn, 200, inspect(bar))
    end

    get "/4/*bar" do
      resp(conn, 200, inspect(bar))
    end

    get "/5/bar-*bar" do
      resp(conn, 200, inspect(bar))
    end

    match "/6/bar" do
      resp(conn, 200, "ok")
    end

    get "/7/:bar" when byte_size(bar) <= 3,
      some_option: :hello,
      do: resp(conn, 200, inspect(bar))

    get "/8/bar baz/:bat" do
      resp(conn, 200, bat)
    end

    get "/9/:bar.json" when bar in ["foo", "bar"] or bar == "baz" do
      if bar == "baz" do
        resp(conn, 200, inspect(bar <> " from or boolean guard"))
      else
        resp(conn, 200, inspect(bar <> " from in guard"))
      end
    end

    get "/9/:bar.json" when bar == "specific_value" and bar not in ["other_value"] do
      resp(conn, 200, inspect(bar <> " from == guard"))
    end

    get "/9/:bar.json" when bar != "value" do
      resp(conn, 200, inspect(bar <> " from != guard"))
    end

    get "/9/:bar.json" do
      resp(conn, 200, inspect(bar))
    end

    get "/9/:bar-foo" do
      resp(conn, 200, inspect(bar))
    end

    get "/9/:bar@foo" do
      resp(conn, 200, inspect(bar))
    end

    get "/10/foo-:bar.json" do
      resp(conn, 200, inspect(bar))
    end

    get "/11/:bar.js.map" do
      resp(conn, 200, inspect(bar))
    end

    get "/11/:foo/:bar@app/baz/:bat.js.map"
        when foo in ["foo"] and bar == "bar" and bat == "bat" do
      resp(
        conn,
        200,
        ([inspect(foo), inspect(bar), inspect(bat)] |> Enum.join(" ")) <> " from boolean guards"
      )
    end

    get "/11/:foo/:bar@app/baz/:bat.js.map" do
      resp(conn, 200, [inspect(foo), inspect(bar), inspect(bat)] |> Enum.join(" "))
    end

    plug = SamplePlug
    opts = :hello
    get "/plug/match", to: SamplePlug
    get "/plug/match/options", to: plug, init_opts: opts

    forward "/step1", to: Reforward
    forward "/forward", to: Forward
    forward "/nested/forward", to: Forward

    match "/params/get/:param" do
      resp(conn, 200, conn.params["param"])
    end

    forward "/params/forward/:param", to: Forward

    get "/options/map", private: %{an_option: :a_value} do
      resp(conn, 200, inspect(conn.private))
    end

    get "/options/assigns", assigns: %{an_option: :a_value} do
      resp(conn, 200, inspect(conn.assigns))
    end

    head "/head" do
      resp(conn, 200, "")
    end

    post "/post" do
      resp(conn, 200, "")
    end

    put "/put" do
      resp(conn, 200, "")
    end

    patch "/patch" do
      resp(conn, 200, "")
    end

    delete "/delete" do
      resp(conn, 200, "")
    end

    options "/options" do
      resp(conn, 200, "")
    end

    forward "/options/forward",
      to: Forward,
      private: %{an_option: :a_value},
      assigns: %{another_option: :another_value}

    plug = SamplePlug
    opts = :hello
    forward "/plug/forward", to: SamplePlug
    forward "/plug/init_opts", to: plug, init_opts: opts, private: %{baz: :qux}

    forward "/plug/forward_local", to: :forward_local
    forward "/plug/forward_local_opts", to: :forward_local, init_opts: opts, private: %{baz: :qux}

    def forward_local(conn, opts) do
      resp(conn, 200, "#{inspect(opts)}")
    end

    match _ do
      resp(conn, 404, "oops")
    end

    defp verify_router_options(conn, _opts) do
      if conn.path_info == ["options", "map"] and is_nil(conn.private[:an_option]) do
        raise "should be able to read option after match"
      end

      conn
    end
  end

  use ExUnit.Case, async: true
  use Plug.Test

  test "dispatch root" do
    conn = call(Sample, conn(:get, "/"))
    assert conn.resp_body == "root"
  end

  test "dispatch literal segment" do
    conn = call(Sample, conn(:get, "/1/bar"))
    assert conn.resp_body == "ok"
  end

  test "dispatch dynamic segment" do
    conn = call(Sample, conn(:get, "/2/value"))
    assert conn.resp_body == ~s("value")
  end

  test "dispatch dynamic segment with prefix" do
    conn = call(Sample, conn(:get, "/3/bar-value"))
    assert conn.resp_body == ~s("value")
  end

  test "dispatch dynamic segment with suffix" do
    conn = call(Sample, conn(:get, "/9/value.json"))
    assert conn.resp_body == ~s("value")
    assert conn.params == %{"bar" => "value"}
    assert conn.path_params == %{"bar" => "value"}

    conn = call(Sample, conn(:get, "/9/value-foo"))
    assert conn.resp_body == ~s("value")
    assert conn.params == %{"bar" => "value"}
    assert conn.path_params == %{"bar" => "value"}

    conn = call(Sample, conn(:get, "/9/value@foo"))
    assert conn.resp_body == ~s("value")
    assert conn.params == %{"bar" => "value"}
    assert conn.path_params == %{"bar" => "value"}

    conn = call(Sample, conn(:get, "/9/value"))
    assert conn.resp_body == "oops"
  end

  test "dispatch dynamic segment with prefix and suffix" do
    conn = call(Sample, conn(:get, "/10/foo-value.json"))
    assert conn.resp_body == ~s("value")
    assert conn.params == %{"bar" => "value"}
    assert conn.path_params == %{"bar" => "value"}

    conn = call(Sample, conn(:get, "/10/foo-value"))
    assert conn.resp_body == "oops"
  end

  test "dispatch dynamic segment with multiple suffixes" do
    conn = call(Sample, conn(:get, "/11/value.js.map"))
    assert conn.resp_body == ~s("value")
    assert conn.params == %{"bar" => "value"}
    assert conn.path_params == %{"bar" => "value"}
  end

  test "dispatch multiple dynamic segments with multiple suffixes" do
    conn = call(Sample, conn(:get, "/11/foo_value/bar_value@app/baz/bat_value.js.map"))
    assert conn.resp_body == ~s("foo_value\" "bar_value" "bat_value")
    assert conn.params == %{"bar" => "bar_value", "bat" => "bat_value", "foo" => "foo_value"}
    assert conn.path_params == %{"bar" => "bar_value", "bat" => "bat_value", "foo" => "foo_value"}

    conn = call(Sample, conn(:get, "/11/foo_value/bar_value/baz/bat_value.js.map"))
    assert conn.resp_body == "oops"

    conn = call(Sample, conn(:get, "/11/foo_value/bar_value@app/baz/bat_value.js"))
    assert conn.resp_body == "oops"

    conn = call(Sample, conn(:get, "/11/foo_value/bar_value/baz/bat_value"))
    assert conn.resp_body == "oops"
  end

  test "dispatch dynamic segment with suffix and var guard" do
    conn = call(Sample, conn(:get, "/9/other_value.json"))
    assert conn.resp_body == ~s("other_value from != guard")
    assert conn.params == %{"bar" => "other_value"}
    assert conn.path_params == %{"bar" => "other_value"}

    conn = call(Sample, conn(:get, "/9/specific_value.json"))
    assert conn.resp_body == ~s("specific_value from == guard")

    conn = call(Sample, conn(:get, "/9/foo.json"))
    assert conn.resp_body == ~s("foo from in guard")

    conn = call(Sample, conn(:get, "/9/bar.json"))
    assert conn.resp_body == ~s("bar from in guard")

    conn = call(Sample, conn(:get, "/9/baz.json"))
    assert conn.resp_body == ~s("baz from or boolean guard")
  end

  test "dispatch dynamic segment with/without suffix and guards" do
    conn = call(Sample, conn(:get, "/11/foo/bar@app/baz/bat.js.map"))
    assert conn.resp_body == ~s("foo\" "bar" "bat" from boolean guards)
    assert conn.params == %{"bar" => "bar", "bat" => "bat", "foo" => "foo"}
    assert conn.path_params == %{"bar" => "bar", "bat" => "bat", "foo" => "foo"}

    conn = call(Sample, conn(:get, "/11/boo/boo-app/baz/boo.js.map"))
    assert conn.resp_body == "oops"
  end

  test "dispatch glob segment" do
    conn = call(Sample, conn(:get, "/4/value"))
    assert conn.resp_body == ~s(["value"])

    conn = call(Sample, conn(:get, "/4/value/extra"))
    assert conn.resp_body == ~s(["value", "extra"])
  end

  test "dispatch glob segment with prefix" do
    conn = call(Sample, conn(:get, "/5/bar-value/extra"))
    assert conn.resp_body == ~s(["bar-value", "extra"])
  end

  test "dispatch custom route" do
    conn = call(Sample, conn(:get, "/6/bar"))
    assert conn.resp_body == "ok"
  end

  test "dispatch with guards" do
    conn = call(Sample, conn(:get, "/7/a"))
    assert conn.resp_body == ~s("a")

    conn = call(Sample, conn(:get, "/7/ab"))
    assert conn.resp_body == ~s("ab")

    conn = call(Sample, conn(:get, "/7/abc"))
    assert conn.resp_body == ~s("abc")

    conn = call(Sample, conn(:get, "/7/abcd"))
    assert conn.resp_body == "oops"
  end

  test "dispatch after decoding guards" do
    conn = call(Sample, conn(:get, "/8/bar baz/bat"))
    assert conn.resp_body == "bat"

    conn = call(Sample, conn(:get, "/8/bar%20baz/bat bag"))
    assert conn.resp_body == "bat bag"

    conn = call(Sample, conn(:get, "/8/bar%20baz/bat%20bag"))
    assert conn.resp_body == "bat bag"
  end

  test "dispatch wrong verb" do
    conn = call(Sample, conn(:post, "/1/bar"))
    assert conn.resp_body == "oops"
  end

  test "dispatch to plug" do
    conn = call(Sample, conn(:get, "/plug/match"))
    assert conn.resp_body == "[]"
  end

  test "dispatch to plug with options" do
    conn = call(Sample, conn(:get, "/plug/match/options"))
    assert conn.resp_body == ":world"
  end

  test "dispatch with forwarding" do
    conn = call(Sample, conn(:get, "/forward"))
    assert conn.resp_body == "forwarded"
    assert conn.path_info == ["forward"]
  end

  test "dispatch with forwarding with custom call" do
    call(Sample, conn(:get, "/forward"))
    assert Process.get(:plug_forward_call, true)
  end

  test "dispatch with forwarding including slashes" do
    conn = call(Sample, conn(:get, "/nested/forward"))
    assert conn.resp_body == "forwarded"
    assert conn.path_info == ["nested", "forward"]
  end

  test "dispatch with forwarding handles urlencoded path segments" do
    conn = call(Sample, conn(:get, "/nested/forward/fancy_id/%2BANcgj1jZc%2F9O%2B"))
    assert conn.resp_body == "+ANcgj1jZc/9O+--%2BANcgj1jZc%2F9O%2B"
  end

  test "dispatch with forwarding handles un-urlencoded path segments" do
    conn = call(Sample, conn(:get, "/nested/forward/fancy_id/+ANcgj1jZc9O+"))
    assert conn.resp_body == "+ANcgj1jZc9O+--+ANcgj1jZc9O+"
  end

  test "dispatch with forwarding modifies script_name" do
    conn = call(Sample, conn(:get, "/nested/forward/script_name"))
    assert conn.resp_body == "nested,forward"

    conn = call(Sample, conn(:get, "/step1/step2/script_name"))
    assert conn.resp_body == "step1,step2"
  end

  test "dispatch any verb" do
    conn = call(Sample, conn(:get, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:post, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:put, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:patch, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:delete, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:options, "/6/bar"))
    assert conn.resp_body == "ok"

    conn = call(Sample, conn(:unknown, "/6/bar"))
    assert conn.resp_body == "ok"
  end

  test "dispatches based on host" do
    conn = call(Sample, conn(:get, "http://foo.bar/"))
    assert conn.resp_body == "foo.bar root"

    conn = call(Sample, conn(:get, "http://foo.other/"))
    assert conn.resp_body == "foo.* root"

    conn = call(Sample, conn(:get, "http://foo.other/script_name"))
    assert conn.resp_body == ""
  end

  test "dispatch not found" do
    conn = call(Sample, conn(:get, "/unknown"))
    assert conn.status == 404
    assert conn.resp_body == "oops"
  end

  @already_sent {:plug_conn, :sent}

  test "handle errors" do
    try do
      call(Sample, conn(:get, "/forward/throw"))
      flunk("oops")
    catch
      :throw, :oops ->
        assert_received @already_sent
        assigns = Process.get(:plug_handle_errors)
        assert assigns.status == 500
        assert assigns.kind == :throw
        assert assigns.reason == :oops
        assert is_list(assigns.stack)
    end
  end

  test "handle errors translates exceptions to status code" do
    try do
      call(Sample, conn(:get, "/forward/raise"))
      flunk("oops")
    rescue
      e in Plug.Conn.WrapperError ->
        %{kind: :error, reason: %Plug.Parsers.RequestTooLargeError{}} = e
        assert_received @already_sent
        assigns = Process.get(:plug_handle_errors)
        assert assigns.status == 413
        assert assigns.kind == :error
        assert assigns.reason.__struct__ == Plug.Parsers.RequestTooLargeError
        assert is_list(assigns.stack)
    end
  end

  test "handle errors when response was sent" do
    try do
      call(Sample, conn(:get, "/forward/send_and_exit"))
      flunk("oops")
    catch
      :exit, :oops ->
        assert_received @already_sent
        assert is_nil(Process.get(:plug_handle_errors))
    end
  end

  test "match_path/1" do
    conn = call(Sample, conn(:get, "/params/get/a_value"))
    assert Plug.Router.match_path(conn) == "/params/get/:param"
  end

  test "match_path/1 on forward to router" do
    conn = call(Sample, conn(:get, "/step1/step2/fancy_id/abc123"))
    assert Plug.Router.match_path(conn) == "/step1/*glob/step2/*glob/fancy_id/:id"
  end

  test "assigns path params to conn params and path_params" do
    conn = call(Sample, conn(:get, "/params/get/a_value"))
    assert conn.params["param"] == "a_value"
    assert conn.path_params["param"] == "a_value"
    assert conn.resp_body == "a_value"
  end

  test "assigns path params to conn params and path_params on forward" do
    conn = call(Sample, conn(:get, "/params/forward/a_value/params"))
    assert conn.params["param"] == "a_value"
    assert conn.path_params["param"] == "a_value"
    assert conn.resp_body == "a_value"
  end

  test "path params have priority over body and query params" do
    conn =
      conn(:post, "/params/get/p_value", "param=b_value")
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:urlencoded]))

    conn = call(Sample, conn)
    assert conn.resp_body == "p_value"
  end

  test "assigns route options to private conn map" do
    conn = call(Sample, conn(:get, "/options/map"))
    assert conn.private[:an_option] == :a_value
    assert conn.resp_body =~ ~s(an_option: :a_value)
  end

  test "assigns route options to assigns conn map on GET requests" do
    conn = call(Sample, conn(:get, "/options/assigns"))
    assert conn.assigns[:an_option] == :a_value
    assert conn.resp_body =~ ~s(an_option: :a_value)
  end

  test "declare and call HEAD requests" do
    conn = call(Sample, conn(:head, "/head"))
    assert conn.status == 200
  end

  test "declare and call POST requests" do
    conn = call(Sample, conn(:post, "/post"))
    assert conn.status == 200
  end

  test "declare and call PUT requests" do
    conn = call(Sample, conn(:put, "/put"))
    assert conn.status == 200
  end

  test "declare and call PATCH requests" do
    conn = call(Sample, conn(:patch, "/patch"))
    assert conn.status == 200
  end

  test "declare and call DELETE requests" do
    conn = call(Sample, conn(:delete, "/delete"))
    assert conn.status == 200
  end

  test "declare and call OPTIONS requests" do
    conn = call(Sample, conn(:options, "/options"))
    assert conn.status == 200
  end

  test "assigns options on forward" do
    conn = call(Sample, conn(:get, "/options/forward"))
    assert conn.private[:an_option] == :a_value
    assert conn.assigns[:another_option] == :another_value
    assert conn.resp_body == "forwarded"
  end

  test "forwards to a plug" do
    conn = call(Sample, conn(:get, "/plug/forward"))
    assert conn.resp_body == "[]"
  end

  test "forwards to a plug with init options" do
    conn = call(Sample, conn(:get, "/plug/init_opts"))
    assert conn.private[:baz] == :qux
    assert conn.resp_body == ":world"
  end

  test "forwards to a function plug" do
    conn = call(Sample, conn(:get, "/plug/forward_local"))
    assert conn.resp_body == "[]"
  end

  test "forwards to a function plug with options" do
    conn = call(Sample, conn(:get, "/plug/forward_local_opts"))
    assert conn.private[:baz] == :qux
    assert conn.resp_body == ":hello"
  end

  test "emit start and stop event when router dispatches" do
    start_router_id = {:start, :rand.uniform(100)}
    stop_router_id = {:stop, :rand.uniform(100)}

    on_exit(fn ->
      :telemetry.detach(start_router_id)
      :telemetry.detach(stop_router_id)
    end)

    attach(start_router_id, [:plug, :router_dispatch, :start])
    attach(stop_router_id, [:plug, :router_dispatch, :stop])

    conn = call(Sample, conn(:get, "/"))
    assert conn.status == 200

    assert_received {:event, [:plug, :router_dispatch, :start], %{system_time: _},
                     %{route: "/", conn: %Plug.Conn{}, router: Sample}}

    assert_received {:event, [:plug, :router_dispatch, :stop], %{duration: _},
                     %{route: "/", conn: %Plug.Conn{}, router: Sample}}
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

  defp call(mod, conn) do
    mod.call(conn, [])
  end
end
