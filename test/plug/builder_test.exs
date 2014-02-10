defmodule Plug.BuilderTest do
  import Plug.Connection

  defmodule Wrapper do
    def init(val) do
      { :init, val }
    end

    def wrap(conn, opts, fun) do
      stack = [{ :wrap, opts }|conn.assigns[:stack]]
      fun.(assign(conn, :stack, stack))
    end
  end

  defmodule Module do
    def init(val) do
      { :init, val }
    end

    def call(conn, opts) do
      stack = [{ :call, opts }|conn.assigns[:stack]]
      assign(conn, :stack, stack)
    end
  end

  defmodule Modfun do
    def func(conn, opts) do
      stack = [{ :modfun, opts }|conn.assigns[:stack]]
      assign(conn, :stack, stack)
    end
  end

  defmodule Sample do
    use Plug.Builder

    plug :fun
    plug Wrapper, :opts
    plug Module, :opts
    plug { Modfun, :func }

    def fun(conn, opts) do
      stack = [{ :fun, opts }|conn.assigns[:stack]]
      assign(conn, :stack, stack)
    end
  end

  use ExUnit.Case, async: true
  use Plug.Test

  test "exports the init/1 function" do
    assert Sample.init(:ok) == :ok
  end

  test "builds plug stack in the order" do
    conn = conn(:get, "/") |> assign(:stack, [])
    assert Sample.call(conn, []).assigns[:stack] ==
           [modfun: [], call: {:init, :opts}, wrap: {:init, :opts}, fun: []]
  end
end
