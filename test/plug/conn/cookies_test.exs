defmodule Plug.Conn.CookiesTest do
  use ExUnit.Case, async: true

  import Plug.Conn.Cookies
  doctest Plug.Conn.Cookies

  @cookies %{
    "key1=value1, key2=value2" => %{"key1" => "value1, key2=value2"},
    "key1=value1; key2=value2" => %{"key1" => "value1", "key2" => "value2"},
    "key space=value, key=value space" => %{},
    "  key1=value1 , key2=value2  " => %{"key1" => "value1 , key2=value2"},
    "$key1=value1, key2=value2; $key3=value3" => %{},
    "" => %{},
    "key, =, value" => %{},
    "key=" => %{"key" => ""},
    "key1=;;key2=" => %{"key1" => "", "key2" => ""},
    "key1=value, with, commas;key2=" => %{"key1" => "value, with, commas", "key2" => ""}
  }

  test "decode cookies" do
    Enum.each(@cookies, fn {content, expected} ->
      assert decode(content) == expected
    end)

    Enum.each(@cookies, fn {content, expected} ->
      assert decode(content, backwards: false) == expected
    end)

    Enum.each(@cookies, fn {content, expected} ->
      assert decode(content, other: true) == expected
    end)
  end

  test "decodes cookies backwards option" do
    assert decode("key1=value1, key2=value2", backwards: true) == %{
             "key1" => "value1",
             "key2" => "value2"
           }

    assert decode("$key1=value1, key2=value2; $key3=value3", backwards: true) == %{
             "key2" => "value2"
           }

    assert decode("key space=value, key=value space", backwards: true) == %{
             "key" => "value space"
           }

    assert decode("  key1=value1 , key2=value2  ", backwards: true) == %{
             "key1" => "value1",
             "key2" => "value2"
           }
  end

  test "decodes encoded cookie" do
    start = {{2012, 9, 29}, {15, 32, 10}}
    cookie = encode("foo", %{value: "bar", max_age: 60, universal_time: start})

    assert decode(cookie) == %{
             "foo" => "bar",
             "expires" => "Sat, 29 Sep 2012 15:33:10 GMT",
             "max-age" => "60",
             "path" => "/"
           }
  end

  test "encodes the cookie" do
    assert encode("foo", %{value: "bar"}) == "foo=bar; path=/; HttpOnly"
    assert encode("foo", %{}) == "foo=; path=/; HttpOnly"
  end

  test "encodes with :path option" do
    assert encode("foo", %{value: "bar", path: "/baz"}) == "foo=bar; path=/baz; HttpOnly"
  end

  test "encodes with :domain option" do
    assert encode("foo", %{value: "bar", domain: "google.com"}) ==
             "foo=bar; path=/; domain=google.com; HttpOnly"
  end

  test "encodes with :secure option" do
    assert encode("foo", %{value: "bar", secure: true}) == "foo=bar; path=/; secure; HttpOnly"
  end

  test "encodes with :http_only option, which defaults to true" do
    assert encode("foo", %{value: "bar", http_only: false}) == "foo=bar; path=/"
  end

  test "encodes with :max_age" do
    start = {{2012, 9, 29}, {15, 32, 10}}

    assert encode("foo", %{value: "bar", max_age: 60, universal_time: start}) ==
             "foo=bar; path=/; expires=Sat, 29 Sep 2012 15:33:10 GMT; max-age=60; HttpOnly"
  end

  test "encodes with :extra option" do
    assert encode("foo", %{value: "bar", extra: "SameSite=Lax"}) ==
             "foo=bar; path=/; HttpOnly; SameSite=Lax"
  end
end
