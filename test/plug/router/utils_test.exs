defmodule Plug.Router.UtilsTest do
  use ExUnit.Case, async: true

  require Plug.Router.Utils, as: R
  doctest Plug.Router.Utils

  @opts [context: Plug.Router.Utils]

  defp build_path_match(route) do
    R.build_path_match(route, Plug.Router.Utils)
  end

  defp build_path_head(route, guard) do
    R.build_path_head(route, guard, Plug.Router.Utils)
  end

  test "split on root" do
    assert R.split("/") == []
    assert R.split("") == []
  end

  test "split single segment" do
    assert R.split("/foo") == ["foo"]
    assert R.split("foo") == ["foo"]
  end

  test "split with more than one segment" do
    assert R.split("/foo/bar") == ["foo", "bar"]
    assert R.split("foo/bar") == ["foo", "bar"]
  end

  test "split removes trailing slash" do
    assert R.split("/foo/bar/") == ["foo", "bar"]
    assert R.split("foo/bar/") == ["foo", "bar"]
  end

  test "build match with literal" do
    assert quote(@opts, do: {[], ["foo"]}) == build_path_match("/foo")
    assert quote(@opts, do: {[], ["foo"]}) == build_path_match("foo")
  end

  test "build match with identifier" do
    assert quote(@opts, do: {[:id], ["foo", id]}) == build_path_match("/foo/:id")
    assert quote(@opts, do: {[:username], ["foo", username]}) == build_path_match("foo/:username")
  end

  test "build match with literal plus identifier" do
    assert quote(@opts, do: {[:id], ["foo", "bar-" <> id]}) == build_path_match("/foo/bar-:id")

    assert quote(@opts, do: {[:username], ["foo", "bar" <> username]}) ==
             build_path_match("foo/bar:username")
  end

  test "build match only with glob" do
    assert quote(@opts, do: {[:bar], bar}) == build_path_match("*bar")
    assert quote(@opts, do: {[:glob], glob}) == build_path_match("/*glob")

    assert quote(@opts, do: {[:bar], ["id-" <> _ | _] = bar}) == build_path_match("id-*bar")
    assert quote(@opts, do: {[:glob], ["id-" <> _ | _] = glob}) == build_path_match("/id-*glob")
  end

  test "build match with glob" do
    assert quote(@opts, do: {[:bar], ["foo" | bar]}) == build_path_match("/foo/*bar")
    assert quote(@opts, do: {[:glob], ["foo" | glob]}) == build_path_match("foo/*glob")
  end

  test "build match with literal plus glob" do
    assert quote(@opts, do: {[:bar], ["foo" | ["id-" <> _ | _] = bar]}) ==
             build_path_match("/foo/id-*bar")

    assert quote(@opts, do: {[:glob], ["foo" | ["id-" <> _ | _] = glob]}) ==
             build_path_match("foo/id-*glob")
  end

  test "build invalid match with empty matches" do
    assert_raise Plug.Router.InvalidSpecError,
                 ": in routes must be followed by lowercase letters or underscore",
                 fn -> build_path_match("/foo/:") end
  end

  test "build invalid match with non word character" do
    assert_raise Plug.Router.InvalidSpecError,
                 ":identifier in routes must be made of letters, numbers and underscores",
                 fn -> build_path_match("/foo/:bar.baz") end
  end

  test "build invalid match with segments after glob" do
    assert_raise Plug.Router.InvalidSpecError,
                 "cannot have a *glob followed by other segments",
                 fn -> build_path_match("/foo/*bar/baz") end
  end

  test "parse invalid dynamic segments containing dynamic suffix" do
    assert_raise Plug.Router.InvalidSpecError,
                 "dynamic suffix (:json) is unsupported",
                 fn -> R.parse_segments("/foo/:bar-:json") end

    assert_raise Plug.Router.InvalidSpecError,
                 "dynamic suffix (:location) is unsupported",
                 fn -> R.parse_segments("/foo/:user@:location") end
  end

  test "parse invalid dynamic segments containing invalid suffix character" do
    assert_raise Plug.Router.InvalidSpecError,
                 "invalid character \":\" in suffix",
                 fn -> R.parse_segments("/foo/:bar.js.:json") end
  end

  test "build path head with dynamic suffix identifier and injected guard" do
    segments = R.parse_segments("/foo/:bar.json")
    params = R.build_path_params_match(segments)
    match = quote(@opts, do: ["foo", bar])
    assert {^match, ^params, new_guard} = build_path_head("/foo/:bar.json", true)

    assert quote(@opts,
             do:
               binary_part(
                 unquote(Macro.var(:bar, nil)),
                 byte_size(unquote(Macro.var(:bar, nil))) - byte_size(unquote(".json")),
                 byte_size(unquote(".json"))
               ) == unquote(".json")
           ) == new_guard
  end

  test "build path head with dynamic suffix identifier with boolean guards" do
    guards = quote(@opts, do: bar == "value" and is_binary(bar))
    assert {_match, _params, new_guard} = build_path_head("/foo/:bar.json", guards)

    assert quote(@opts,
             do:
               binary_part(
                 unquote(Macro.var(:bar, nil)),
                 byte_size(unquote(Macro.var(:bar, nil))) - byte_size(unquote(".json")),
                 byte_size(unquote(".json"))
               ) == unquote(".json") and (bar == "value.json" and is_binary(bar))
           ) == new_guard
  end

  test "build path head with dynamic suffix identifier with unsupported guard" do
    unsupported_guard = quote(@opts, do: byte_size(bar))

    assert_raise Plug.Router.InvalidSpecError,
                 ":byte_size currently is an unsupported guard function for :bar suffix identifier",
                 fn -> build_path_head("/foo/:bar.json", unsupported_guard) end
  end
end
