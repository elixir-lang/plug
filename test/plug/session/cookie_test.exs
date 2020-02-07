defmodule Plug.Session.CookieTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Plug.Session.COOKIE, as: CookieStore

  @default_opts [
    store: :cookie,
    key: "foobar",
    encryption_salt: "encrypted cookie salt",
    signing_salt: "signing salt",
    log: false
  ]

  @secret String.duplicate("abcdef0123456789", 8)
  @active_secrets [
    String.duplicate("ghijkl0123456789", 8),
    String.duplicate("mnopqr0123456789", 8)
  ]

  opts = Keyword.put(@default_opts, :encrypt, false)
  @signing_opts Plug.Session.init(opts)
  opts = Keyword.put(opts, :active_secret_key_bases, @active_secrets)
  @rotating_signing_opts Plug.Session.init(opts)

  @encrypted_opts Plug.Session.init(@default_opts)
  opts = Keyword.put(@default_opts, :active_secret_key_bases, @active_secrets)
  @rotating_encrypted_opts Plug.Session.init(opts)

  defmodule CustomSerializer do
    def encode(%{"foo" => "bar"}), do: {:ok, "encoded session"}
    def encode(%{"foo" => "baz"}), do: {:ok, "another encoded session"}
    def encode(%{}), do: {:ok, ""}
    def encode(_), do: :error

    def decode("encoded session"), do: {:ok, %{"foo" => "bar"}}
    def decode("another encoded session"), do: {:ok, %{"foo" => "baz"}}
    def decode(nil), do: {:ok, nil}
    def decode(_), do: :error
  end

  opts = Keyword.put(@default_opts, :serializer, CustomSerializer)
  @custom_serializer_opts Plug.Session.init(opts)

  defp sign_conn(conn, secret \\ @secret, opts \\ @signing_opts) do
    put_in(conn.secret_key_base, secret)
    |> Plug.Session.call(opts)
    |> fetch_session
  end

  defp encrypt_conn(conn, secret \\ @secret, opts \\ @encrypted_opts) do
    put_in(conn.secret_key_base, secret)
    |> Plug.Session.call(opts)
    |> fetch_session
  end

  defp custom_serialize_conn(conn) do
    put_in(conn.secret_key_base, @secret)
    |> Plug.Session.call(@custom_serializer_opts)
    |> fetch_session
  end

  def returns_arg(arg), do: arg

  defp apply_mfa({module, function, args}), do: apply(module, function, args)

  test "requires signing_salt option to be defined" do
    assert_raise ArgumentError, ~r/expects :signing_salt as option/, fn ->
      Plug.Session.init(Keyword.delete(@default_opts, :signing_salt))
    end
  end

  test "requires the secret to be at least 64 bytes" do
    assert_raise ArgumentError, ~r/to be at least 64 bytes/, fn ->
      conn(:get, "/")
      |> sign_conn("abcdef")
      |> put_session("foo", "bar")
      |> send_resp(200, "OK")
    end
  end

  test "defaults key generator opts" do
    key_generator_opts = CookieStore.init(@default_opts).key_opts
    assert key_generator_opts[:iterations] == 1000
    assert key_generator_opts[:length] == 32
    assert key_generator_opts[:digest] == :sha256
  end

  test "uses specified key generator opts" do
    opts =
      @default_opts
      |> Keyword.put(:key_iterations, 2000)
      |> Keyword.put(:key_length, 64)
      |> Keyword.put(:key_digest, :sha)

    key_generator_opts = CookieStore.init(opts).key_opts
    assert key_generator_opts[:iterations] == 2000
    assert key_generator_opts[:length] == 64
    assert key_generator_opts[:digest] == :sha
  end

  test "requires serializer option to be an atom" do
    assert_raise ArgumentError, ~r/expects :serializer option to be a module/, fn ->
      Plug.Session.init(Keyword.put(@default_opts, :serializer, "CustomSerializer"))
    end
  end

  test "uses :external_term_format cookie serializer by default" do
    assert Plug.Session.init(@default_opts).store_config.serializer == :external_term_format
  end

  test "uses custom cookie serializer" do
    assert @custom_serializer_opts.store_config.serializer == CustomSerializer
  end

  test "uses MFAs for salts" do
    opts = [
      store: :cookie,
      key: "foobar",
      encryption_salt: {__MODULE__, :returns_arg, ["encrypted cookie salt"]},
      signing_salt: {__MODULE__, :returns_arg, ["signing salt"]}
    ]

    plug = Plug.Session.init(opts)
    assert apply_mfa(plug.store_config.encryption_salt) == "encrypted cookie salt"
    assert apply_mfa(plug.store_config.signing_salt) == "signing salt"
  end

  ## Signed

  test "session cookies are signed" do
    conn = %{secret_key_base: @secret}
    cookie = CookieStore.put(conn, nil, %{"foo" => "baz"}, @signing_opts.store_config)
    assert is_binary(cookie)
    assert CookieStore.get(conn, cookie, @signing_opts.store_config) == {:term, %{"foo" => "baz"}}
    assert CookieStore.get(conn, "bad", @signing_opts.store_config) == {nil, %{}}
  end

  test "gets and sets signed session cookie" do
    conn =
      conn(:get, "/")
      |> sign_conn()
      |> put_session("foo", "bar")
      |> send_resp(200, "")

    assert conn(:get, "/")
           |> recycle_cookies(conn)
           |> sign_conn()
           |> get_session("foo") == "bar"
  end

  test "deletes signed session cookie" do
    conn =
      conn(:get, "/")
      |> sign_conn()
      |> put_session("foo", "bar")
      |> configure_session(drop: true)
      |> send_resp(200, "")

    assert conn(:get, "/")
           |> recycle_cookies(conn)
           |> sign_conn()
           |> get_session("foo") == nil
  end

  test "gets (with active secret) and sets (with primary secret) signed session cookie" do
    conn =
      conn(:get, "/")
      |> sign_conn(Enum.at(@active_secrets, 1))
      |> put_session("foo", "bar")
      |> send_resp(200, "")

    assert conn(:get, "/")
           |> recycle_cookies(conn)
           |> sign_conn(@secret, @rotating_signing_opts)
           |> get_session("foo") == "bar"
  end

  ## Encrypted

  test "session cookies are encrypted" do
    conn = %{secret_key_base: @secret}
    cookie = CookieStore.put(conn, nil, %{"foo" => "baz"}, @encrypted_opts.store_config)
    assert is_binary(cookie)

    assert CookieStore.get(conn, cookie, @encrypted_opts.store_config) ==
             {:term, %{"foo" => "baz"}}

    assert CookieStore.get(conn, "bad", @encrypted_opts.store_config) == {nil, %{}}
  end

  test "gets and sets encrypted session cookie" do
    conn =
      conn(:get, "/")
      |> encrypt_conn()
      |> put_session("foo", "bar")
      |> send_resp(200, "")

    assert conn(:get, "/")
           |> recycle_cookies(conn)
           |> encrypt_conn()
           |> get_session("foo") == "bar"
  end

  test "deletes encrypted session cookie" do
    conn =
      conn(:get, "/")
      |> encrypt_conn()
      |> put_session("foo", "bar")
      |> configure_session(drop: true)
      |> send_resp(200, "")

    assert conn(:get, "/")
           |> recycle_cookies(conn)
           |> encrypt_conn()
           |> get_session("foo") == nil
  end

  test "gets (with active secret) and sets (with primary secret) encrypted session cookie" do
    conn =
      conn(:get, "/")
      |> encrypt_conn(Enum.at(@active_secrets, 0))
      |> put_session("foo", "bar")
      |> send_resp(200, "")

    assert conn(:get, "/")
           |> recycle_cookies(conn)
           |> encrypt_conn(@secret, @rotating_encrypted_opts)
           |> get_session("foo") == "bar"
  end

  ## Custom Serializer

  test "session cookies are serialized by the custom serializer" do
    conn = %{secret_key_base: @secret}
    cookie = CookieStore.put(conn, nil, %{"foo" => "baz"}, @custom_serializer_opts.store_config)
    assert is_binary(cookie)

    assert CookieStore.get(conn, cookie, @custom_serializer_opts.store_config) ==
             {:custom, %{"foo" => "baz"}}
  end

  test "gets and sets custom serialized session cookie" do
    conn =
      conn(:get, "/")
      |> custom_serialize_conn()
      |> put_session("foo", "bar")
      |> send_resp(200, "")

    assert conn(:get, "/")
           |> recycle_cookies(conn)
           |> custom_serialize_conn()
           |> get_session("foo") == "bar"
  end

  test "deletes custom serialized session cookie" do
    conn =
      conn(:get, "/")
      |> custom_serialize_conn()
      |> put_session("foo", "bar")
      |> configure_session(drop: true)
      |> send_resp(200, "")

    assert conn(:get, "/")
           |> recycle_cookies(conn)
           |> custom_serialize_conn()
           |> get_session("foo") == nil
  end
end
