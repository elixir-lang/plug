defmodule Plug.RouterTest do
  defmodule Sample do
    use Plug.Router

    import Plug.Connection

    get "/" do
      { :ok, conn |> resp(200, "root") }
    end

    get "/1/bar" do
      { :ok, conn |> resp(200, "ok") }
    end

    get "/2/:bar" do
      { :ok, conn |> resp(200, inspect(bar)) }
    end

    get "/3/bar-:bar" do
      { :ok, conn |> resp(200, inspect(bar)) }
    end

    get "/4/*bar" do
      { :ok, conn |> resp(200, inspect(bar)) }
    end

    get "/5/bar-*bar" do
      { :ok, conn |> resp(200, inspect(bar)) }
    end

    get ["6", "bar"] do
      { :ok, conn |> resp(200, "ok") }
    end

    get "/7/:bar" when size(bar) <= 3 do
      { :ok, conn |> resp(200, inspect(bar)) }
    end

    match ["8", "bar"] do
      { :ok, conn |> resp(200, "ok") }
    end

    match _ do
      { :ok, conn |> resp(404, "oops") }
    end
  end

  use ExUnit.Case, async: true
  use Plug.Test

  test "dispatch root" do
    assert { :ok, conn } = call(Sample, conn(:get, "/"))
    assert conn.resp_body == "root"
  end

  test "dispatch literal segment" do
    assert { :ok, conn } = call(Sample, conn(:get, "/1/bar"))
    assert conn.resp_body == "ok"
  end

  test "dispatch dynamic segment" do
    assert { :ok, conn } = call(Sample, conn(:get, "/2/value"))
    assert conn.resp_body == %s("value")
  end

  test "dispatch dynamic segment with prefix" do
    assert { :ok, conn } = call(Sample, conn(:get, "/3/bar-value"))
    assert conn.resp_body == %s("value")
  end

  test "dispatch glob segment" do
    assert { :ok, conn } = call(Sample, conn(:get, "/4/value"))
    assert conn.resp_body == %s(["value"])

    assert { :ok, conn } = call(Sample, conn(:get, "/4/value/extra"))
    assert conn.resp_body == %s(["value", "extra"])
  end

  test "dispatch glob segment with prefix" do
    assert { :ok, conn } = call(Sample, conn(:get, "/5/bar-value/extra"))
    assert conn.resp_body == %s(["bar-value", "extra"])
  end

  test "dispatch custom route" do
    assert { :ok, conn } = call(Sample, conn(:get, "/6/bar"))
    assert conn.resp_body == "ok"
  end

  test "dispatch with guards" do
    assert { :ok, conn } = call(Sample, conn(:get, "/7/a"))
    assert conn.resp_body == %s("a")

    assert { :ok, conn } = call(Sample, conn(:get, "/7/ab"))
    assert conn.resp_body == %s("ab")

    assert { :ok, conn } = call(Sample, conn(:get, "/7/abc"))
    assert conn.resp_body == %s("abc")

    assert { :ok, conn } = call(Sample, conn(:get, "/7/abcd"))
    assert conn.resp_body == "oops"
  end

  test "dispatch wrong verb" do
    assert { :ok, conn } = call(Sample, conn(:post, "/1/bar"))
    assert conn.resp_body == "oops"
  end

  test "dispatch any verb" do
    assert { :ok, conn } = call(Sample, conn(:get, "/8/bar"))
    assert conn.resp_body == "ok"

    assert { :ok, conn } = call(Sample, conn(:post, "/8/bar"))
    assert conn.resp_body == "ok"

    assert { :ok, conn } = call(Sample, conn(:put, "/8/bar"))
    assert conn.resp_body == "ok"

    assert { :ok, conn } = call(Sample, conn(:patch, "/8/bar"))
    assert conn.resp_body == "ok"

    assert { :ok, conn } = call(Sample, conn(:delete, "/8/bar"))
    assert conn.resp_body == "ok"

    assert { :ok, conn } = call(Sample, conn(:options, "/8/bar"))
    assert conn.resp_body == "ok"

    assert { :ok, conn } = call(Sample, conn(:unknown, "/8/bar"))
    assert conn.resp_body == "ok"
  end

  test "dispatch not found" do
    assert { :ok, conn } = call(Sample, conn(:get, "/unknown"))
    assert conn.status == 404
    assert conn.resp_body == "oops"
  end

  defp call(mod, conn) do
    mod.call(conn, [])
  end
end
