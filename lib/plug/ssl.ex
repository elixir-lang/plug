defmodule Plug.SSL do
  @moduledoc """
  A plug to force SSL connections and enable HSTS.

  If the scheme of a request is `https`, it'll add a `strict-transport-security`
  header to enable HTTP Strict Transport Security by default.

  Otherwise, the request will be redirected to a corresponding location
  with the `https` scheme by setting the `location` header of the response.
  The status code will be 301 if the method of `conn` is `GET` or `HEAD`,
  or 307 in other situations.

  Besides being a Plug, this module also provides conveniences for configuring
  SSL. See `configure/1`.

  ## x-forwarded-proto

  If your Plug application is behind a proxy that handles HTTPS, you will
  need to tell Plug to parse the proper protocol from the `x-forwarded-proto`
  header. This can be done using the `:rewrite_port_on` option:

      plug Plug.SSL, rewrite_port_on: [:x_forwarded_proto]

  The command above will effectively change the value of `conn.scheme` to the
  one sent in `x-forwarded-proto`. If the incoming request comes into a
  standard port (80 for HTTP or 443 for HTTPS), the command above will also
  change the value of `conn.port` to match the new scheme.

  Since rewriting the scheme based on `x-forwarded-proto` can open up
  security vulnerabilities, only provide the option above if:

    * your app is behind a proxy
    * your proxy strips `x-forwarded-proto` headers from all incoming requests
    * your proxy sets the `x-forwarded-proto` and sends it to Plug

  ## x-forwarded-host

  Similarly to the `x-forwarded-proto` case, if you Plug application is behind
  a proxy (for example in Kubernetes environment) an internal host may be different
  then exposed to the internet. In that case, load balancer handling the request will
  make an internal call to your Plug application using some internal hostname
  (like some.service.svc.cluster.local). Then redirect based on `host` header will be wrong.

  Fortunately load balancers provide host used by end-user to make a request in
  `x-forwarded-host` header. To do such redirect based on that header use
  `:rewrite_host_on` option:

      plug Plug.SSL, rewrite_host_on: [:x_forwarded_host]

  The command above will effectively change the value of `conn.host` to the
  one sent in `x-forwarded-host`.

  Same as with `x-forwarded-proto`, only provide the option above if:

    * your app is behind a proxy
    * your proxy strips `x-forwarded-host` headers from all incoming requests
    * your proxy sets the `x-forwarded-host` and sends it to Plug

  ## Plug Options

    * `:rewrite_port_on` - rewrites the scheme to https based on the given headers
    * `:rewrite_host_on` - rewrites the host while redirecting to https based on the given headers
    * `:hsts` - a boolean on enabling HSTS or not, defaults to `true`
    * `:expires` - seconds to expires for HSTS, defaults to `31_536_000` (1 year)
    * `:preload` - a boolean to request inclusion on the HSTS preload list
      (for full set of required flags, see: [Chromium HSTS submission site](https://hstspreload.org)),
      defaults to `false`
    * `:subdomains` - a boolean on including subdomains or not in HSTS,
      defaults to `false`
    * `:exclude` - exclude the given hosts from redirecting to the `https`
      scheme. Defaults to `["localhost"]`
    * `:host` - a new host to redirect to if the request's scheme is `http`,
      defaults to `conn.host`. It may be set to a binary or a tuple
      `{module, function, args}` that will be invoked on demand. This setting overrides
      rewrite_host_on option.
    * `:log` - The log level at which this plug should log its request info.
      Default is `:info`. Can be `false` to disable logging.

  ## Port

  It is not possible to directly configure the port in `Plug.SSL` because
  HSTS expects the port to be 443 for SSL. If you are not using HSTS and
  want to redirect to HTTPS on another port, you can sneak it alongside
  the host, for example: `host: "example.com:443"`.
  """
  @behaviour Plug

  require Logger
  import Plug.Conn

  @strong_tls_ciphers [
    'ECDHE-RSA-AES256-GCM-SHA384',
    'ECDHE-ECDSA-AES256-GCM-SHA384',
    'ECDHE-RSA-AES128-GCM-SHA256',
    'ECDHE-ECDSA-AES128-GCM-SHA256',
    'DHE-RSA-AES256-GCM-SHA384',
    'DHE-RSA-AES128-GCM-SHA256'
  ]

  @compatible_tls_ciphers [
    'ECDHE-RSA-AES256-GCM-SHA384',
    'ECDHE-ECDSA-AES256-GCM-SHA384',
    'ECDHE-RSA-AES128-GCM-SHA256',
    'ECDHE-ECDSA-AES128-GCM-SHA256',
    'DHE-RSA-AES256-GCM-SHA384',
    'DHE-RSA-AES128-GCM-SHA256',
    'ECDHE-RSA-AES256-SHA384',
    'ECDHE-ECDSA-AES256-SHA384',
    'ECDHE-RSA-AES128-SHA256',
    'ECDHE-ECDSA-AES128-SHA256',
    'DHE-RSA-AES256-SHA256',
    'DHE-RSA-AES128-SHA256',
    'ECDHE-RSA-AES256-SHA',
    'ECDHE-ECDSA-AES256-SHA',
    'ECDHE-RSA-AES128-SHA',
    'ECDHE-ECDSA-AES128-SHA'
  ]

  @eccs [
    :secp256r1,
    :secp384r1,
    :secp521r1
  ]

  @doc """
  Configures and validates the options given to the `:ssl` application.

  This function is often called internally by adapters, such as Cowboy,
  to validate and set reasonable defaults for SSL handling. Therefore
  Plug users are not expected to invoke it directly, rather you pass
  the relevant SSL options to your adapter which then invokes this.

  ## Options

  This function accepts all options defined
  [in Erlang/OTP `:ssl` documentation](http://erlang.org/doc/man/ssl.html).

  Besides the options from `:ssl`, this function adds on extra option:

    * `:cypher_suite` - it may be `:strong` or `:compatible`,
      as outlined in the following section

  Furthermore, it sets the following defaults:

    * `secure_renegotiate: true` - to avoid certain types of man-in-the-middle attacks
    * `reuse_sessions: true` - for improved handshake performance of recurring connections

  For a complete guide on HTTPS and best pratices, see [our Plug HTTPS Guide](https.html).

  ## Cipher Suites

  To simplify configuration of TLS defaults, this function provides two preconfigured
  options: `cipher_suite: :strong` and `cipher_suite: :compatible`. The Ciphers
  chosen and related configuration come from the [OWASP Cipher String Cheat
  Sheet](https://www.owasp.org/index.php/TLS_Cipher_String_Cheat_Sheet)

  We've made two modifications to the suggested config from the OWASP recommendations.
  First we include ECDSA certificates which are excluded from their configuration.
  Second we have changed the order of the ciphers to deprioritize DHE because of
  performance implications noted within the OWASP post itself. As the article notes
  "...the TLS handshake with DHE hinders the CPU about 2.4 times more than ECDHE".

  The **Strong** cipher suite only supports tlsv1.2. Ciphers were based on the OWASP
  Group A+ and includes support for RSA or ECDSA certificates. The intention of this
  configuration is to provide as secure as possible defaults knowing that it will not
  be fully compatible with older browsers and operating systems.

  The **Compatible** cipher suite supports tlsv1, tlsv1.1 and tlsv1.2. Ciphers were
  based on the OWASP Group B and includes support for RSA or ECDSA certificates. The
  intention of this configuration is to provide as secure as possible defaults that
  still maintain support for older browsers and Android versions 4.3 and earlier

  For both suites we've specified certificate curves secp256r1, ecp384r1 and secp521r1.
  Since OWASP doesn't prescribe curves we've based the selection on [Mozilla's
  recommendations](https://wiki.mozilla.org/Security/Server_Side_TLS#Cipher_names_correspondence_table)

  **The cipher suites were last updated on 2018-JUN-14.**
  """
  @spec configure(Keyword.t()) :: {:ok, Keyword.t()} | {:error, String.t()}
  def configure(options) do
    options
    |> check_for_missing_keys()
    |> validate_ciphers()
    |> normalize_ssl_files()
    |> convert_to_charlist()
    |> set_secure_defaults()
    |> configure_managed_tls()
  catch
    {:configure, message} -> {:error, message}
  else
    options -> {:ok, options}
  end

  defp check_for_missing_keys(options) do
    has_sni? = Keyword.has_key?(options, :sni_hosts) or Keyword.has_key?(options, :sni_fun)
    has_key? = Keyword.has_key?(options, :key) or Keyword.has_key?(options, :keyfile)
    has_cert? = Keyword.has_key?(options, :cert) or Keyword.has_key?(options, :certfile)

    cond do
      has_sni? -> options
      not has_key? -> fail("missing option :key/:keyfile")
      not has_cert? -> fail("missing option :cert/:certfile")
      true -> options
    end
  end

  defp normalize_ssl_files(options) do
    ssl_files = [:keyfile, :certfile, :cacertfile, :dhfile]
    Enum.reduce(ssl_files, options, &normalize_ssl_file(&1, &2))
  end

  defp normalize_ssl_file(key, options) do
    value = options[key]

    cond do
      is_nil(value) ->
        options

      Path.type(value) == :absolute ->
        put_ssl_file(options, key, value)

      true ->
        put_ssl_file(options, key, Path.expand(value, otp_app(options)))
    end
  end

  defp put_ssl_file(options, key, value) do
    value = to_charlist(value)

    unless File.exists?(value) do
      message =
        "the file #{value} required by SSL's #{inspect(key)} either does not exist, " <>
          "or the application does not have permission to access it"

      fail(message)
    end

    Keyword.put(options, key, value)
  end

  defp otp_app(options) do
    if app = options[:otp_app] do
      Application.app_dir(app)
    else
      fail("the :otp_app option is required when setting relative SSL certfiles")
    end
  end

  defp convert_to_charlist(options) do
    Enum.reduce([:password], options, fn key, acc ->
      if value = acc[key] do
        Keyword.put(acc, key, to_charlist(value))
      else
        acc
      end
    end)
  end

  defp set_secure_defaults(options) do
    options
    |> Keyword.put_new(:secure_renegotiate, true)
    |> Keyword.put_new(:reuse_sessions, true)
  end

  defp configure_managed_tls(options) do
    {cipher_suite, options} = Keyword.pop(options, :cipher_suite)

    case cipher_suite do
      :strong -> set_strong_tls_defaults(options)
      :compatible -> set_compatible_tls_defaults(options)
      nil -> options
      _ -> fail("unknown :cipher_suite named #{inspect(cipher_suite)}")
    end
  end

  defp set_managed_tls_defaults(options) do
    options
    |> Keyword.put_new(:honor_cipher_order, true)
    |> Keyword.put_new(:eccs, @eccs)
  end

  defp set_strong_tls_defaults(options) do
    options
    |> set_managed_tls_defaults
    |> Keyword.put_new(:ciphers, @strong_tls_ciphers)
    |> Keyword.put_new(:versions, [:"tlsv1.2"])
  end

  defp set_compatible_tls_defaults(options) do
    options
    |> set_managed_tls_defaults
    |> Keyword.put_new(:ciphers, @compatible_tls_ciphers)
    |> Keyword.put_new(:versions, [:"tlsv1.2", :"tlsv1.1", :tlsv1])
  end

  defp validate_ciphers(options) do
    options
    |> Keyword.get(:ciphers, [])
    |> Enum.each(&validate_cipher/1)

    options
  end

  defp validate_cipher(cipher) do
    if is_binary(cipher) do
      message =
        "invalid cipher #{inspect(cipher)} in cipher list. " <>
          "Strings (double-quoted) are not allowed in ciphers. " <>
          "Ciphers must be either charlists (single-quoted) or tuples. " <>
          "See the ssl application docs for reference"

      fail(message)
    end
  end

  defp fail(message) when is_binary(message) do
    throw({:configure, message})
  end

  @impl true
  def init(opts) do
    host = Keyword.get(opts, :host)
    deprecated_rewrite_on = Keyword.get(opts, :rewrite_on, [])
    rewrite_port_on = Keyword.get(opts, :rewrite_port_on, deprecated_rewrite_on)
    rewrite_host_on = Keyword.get(opts, :rewrite_host_on, [])
    log = Keyword.get(opts, :log, :info)
    exclude = Keyword.get(opts, :exclude, ["localhost"])
    {hsts_header(opts), exclude, host, rewrite_port_on, rewrite_host_on, log}
  end

  @impl true
  def call(conn, {hsts, exclude, host, rewrites_scheme, rewrites_host, log_level}) do
    conn =
      conn
      |> rewrite_port_on(rewrites_scheme)
      |> rewrite_host_on(rewrites_host)

    cond do
      :lists.member(conn.host, exclude) -> conn
      conn.scheme == :https -> put_hsts_header(conn, hsts)
      true -> redirect_to_https(conn, host, log_level)
    end
  end

  defp rewrite_port_on(conn, rewrites) do
    Enum.reduce(rewrites, conn, fn
      :x_forwarded_proto, acc ->
        scheme = get_req_header(acc, "x-forwarded-proto")
        set_scheme(acc, scheme)

      other, _acc ->
        raise "unknown rewrite: #{inspect(other)}"
    end)
  end

  defp set_scheme(%{scheme: :http, port: 80} = conn, ["https"]) do
    %{conn | scheme: :https, port: 443}
  end

  defp set_scheme(conn, ["https"]) do
    %{conn | scheme: :https}
  end

  defp set_scheme(%{scheme: :https, port: 443} = conn, ["http"]) do
    %{conn | scheme: :http, port: 80}
  end

  defp set_scheme(conn, ["http"]) do
    %{conn | scheme: :http}
  end

  defp set_scheme(conn, _scheme) do
    conn
  end

  defp rewrite_host_on(conn, rewrites) do
    Enum.reduce(rewrites, conn, fn
      :x_forwarded_host, acc ->
        scheme = get_req_header(acc, "x-forwarded-host")
        set_host(acc, scheme)

      other, _acc ->
        raise "unknown rewrite: #{inspect(other)}"
    end)
  end

  defp set_host(conn, [proper_host]) do
    %{conn | host: proper_host}
  end

  defp set_host(conn, _), do: conn

  # http://tools.ietf.org/html/draft-hodges-strict-transport-sec-02
  defp hsts_header(opts) do
    if Keyword.get(opts, :hsts, true) do
      expires = Keyword.get(opts, :expires, 31_536_000)
      preload = Keyword.get(opts, :preload, false)
      subdomains = Keyword.get(opts, :subdomains, false)

      "max-age=#{expires}" <>
        if(preload, do: "; preload", else: "") <>
        if(subdomains, do: "; includeSubDomains", else: "")
    end
  end

  defp put_hsts_header(conn, hsts_header) when is_binary(hsts_header) do
    put_resp_header(conn, "strict-transport-security", hsts_header)
  end

  defp put_hsts_header(conn, nil), do: conn

  defp redirect_to_https(%{host: host} = conn, custom_host, log_level) do
    status = if conn.method in ~w(HEAD GET), do: 301, else: 307

    scheme_and_host = "https://" <> host(custom_host, host)
    location = scheme_and_host <> conn.request_path <> qs(conn.query_string)

    log_level &&
      Logger.log(log_level, fn ->
        [
          "Plug.SSL is redirecting ",
          conn.method,
          ?\s,
          conn.request_path,
          " to ",
          scheme_and_host,
          " with status ",
          Integer.to_string(status)
        ]
      end)

    conn
    |> put_resp_header("location", location)
    |> send_resp(status, "")
    |> halt
  end

  defp host(nil, host), do: host
  defp host(host, _) when is_binary(host), do: host
  defp host({mod, fun, args}, host), do: host(apply(mod, fun, args), host)
  # TODO: Deprecate this format
  defp host({:system, env}, host), do: host(System.get_env(env), host)

  defp qs(""), do: ""
  defp qs(qs), do: "?" <> qs
end
