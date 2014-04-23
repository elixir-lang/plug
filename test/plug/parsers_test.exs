defmodule Plug.ParsersTest do
  use ExUnit.Case, async: true

  import Plug.Test

  def parse(conn, opts \\ []) do
    opts = Keyword.put_new(opts, :parsers, [Plug.Parsers.URLENCODED, Plug.Parsers.MULTIPART, Plug.Parsers.JSON])
    Plug.Parsers.call(conn, Plug.Parsers.init(opts))
  end

  test "raises when no parsers is given" do
    assert_raise ArgumentError, fn ->
      parse(conn(:get, "/"), parsers: nil)
    end
  end

  test "parses query string information" do
    conn = parse(conn(:get, "/?foo=bar"))
    assert conn.params["foo"] == "bar"
  end

  test "parses url encoded bodies" do
    headers = [{"content-type", "application/x-www-form-urlencoded"}]
    conn = parse(conn(:get, "/?foo=bar", "foo=baz", headers: headers))
    assert conn.params["foo"] == "baz"
  end

  test "parses json encoded bodies" do
    headers = [{"content-type", "application/json"}]
    conn = parse(conn(:get, "/?foo=bar", "{\"foo\": \"baz\"}", headers: headers))
    assert conn.params["foo"] == "baz"
  end

  test "parses multipart bodies" do
    conn = parse(conn(:get, "/?foo=bar", [foo: "baz"]))
    assert conn.params["foo"] == "baz"
  end

  test "raises on too large bodies" do
    exception = assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      headers = [{"content-type", "application/x-www-form-urlencoded"}]
      parse(conn(:get, "/?foo=bar", "foo=baz", headers: headers), limit: 5)
    end
    assert Plug.Exception.status(exception) == 413
  end

  test "raises when request cannot be processed" do
    exception = assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn ->
      headers = [{"content-type", "text/plain"}]
      parse(conn(:get, "/?foo=bar", "foo=baz", headers: headers))
    end
    assert Plug.Exception.status(exception) == 415
  end
end
