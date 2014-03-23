alias Plug.Connection.Unfetched

defrecord Plug.Conn,
    adapter: nil,
    assigns: [],
    before_send: [],
    cookies: Unfetched[aspect: :cookies],
    host: nil,
    method: nil,
    params: Unfetched[aspect: :params],
    path_info: [],
    port: nil,
    private: [],
    query_string: nil,
    req_cookies: Unfetched[aspect: :cookies],
    req_headers: [],
    resp_body: nil,
    resp_cookies: [],
    resp_headers: [{"cache-control", "max-age=0, private, must-revalidate"}],
    peer: nil,
    scheme: nil,
    script_name: [],
    state: :unset,
    status: nil do

  @type adapter      :: { module, term }
  @type assigns      :: Keyword.t
  @type before_send  :: [(t -> t)]
  @type body         :: iodata | nil
  @type cookies      :: [{ binary, binary }]
  @type headers      :: [{ binary, binary }]
  @type host         :: binary
  @type method       :: binary
  @type scheme       :: :http | :https
  @type segments     :: [binary]
  @type state        :: :unset | :set | :file | :chunked | :sent
  @type status       :: non_neg_integer
  @type param        :: binary | [{ binary, param }] | [param]
  @type params       :: [{ binary, param }]
  @type resp_cookies :: [{ binary, Keyword.t }]

  record_type adapter: adapter,
              assigns: assigns,
              before_send: before_send,
              cookies: cookies | Unfetched.t,
              host: host,
              method: method,
              params: params | Unfetched.t,
              path_info: segments,
              port: 0..65535,
              private: assigns,
              req_cookies: cookies | Unfetched.t,
              req_headers: [],
              resp_body: body,
              resp_cookies: resp_cookies,
              resp_headers: headers,
              scheme: scheme,
              script_name: segments,
              state: state,
              status: status

  @moduledoc """
  The connection record

  It is recommended to use the record for reading data,
  all connection manipulation should be done via the functions
  in `Plug.Connection` module.

  Both request and response headers are expected to have
  lower-cased keys.

  ## Request fields

  Those fields contain request information:

  * `host` - the requested host as a binary, example: `"www.example.com"`
  * `method` - the request method as a binary, example: `"GET"`
  * `path_info` - the path split into segments, example: `["hello", "world"]`
  * `port` - the requested port as an integer, example: `80`
  * `req_headers` - the request headers as a list, example: `[{ "content-type", "text/plain" }]`
  * `scheme` - the request scheme as an atom, example: `:http`
  * `query_string` - the request query string as a binary, example: `"foo=bar"`
  * `peer` - the request IP address and port as a tuple, example: {"60.145.144.120", 80}

  ## Fetchable fields

  Those fields contain request information and they need to be explicitly fetched.
  Before fetching those fields return a `Plug.Connection.Unfetched` record.

  * `cookies`- the request cookies with the response cookies
  * `params` - the request params
  * `req_cookies` - the request cookies (without the response ones)

  ## Response fields

  Those fields contain response information:

  * `resp_body` - the response body, by default is an empty string.
                  It it set to nil after the response is set, except for test connections.
  * `resp_charset` - the response charset, defaults to "utf-8"
  * `resp_content_type` - the response content-type, by default is nil
  * `resp_cookies` - the response cookies with their name and options
  * `resp_headers` - the response headers as a dict,
                     by default `cache-control` is set to `"max-age=0, private, must-revalidate"`
  * `status` - the response status

  Furthermore, the `before_send` field stores callbacks that are invoked
  before the connection is sent. Callbacks are invoked in the reverse order
  they are registed (callbacks registered first are invoked last) in order
  to mimic a Plug stack behaviour.

  ## Connection fields

  * `assigns` - shared user data as a dict
  * `state` - the connection state

  The connection state is used to track the connection lifecycle. It starts
  as `:unset` but is changed to `:set` (via `Plug.Connection.resp/3`) or `:file`
  (when invoked via `Plug.Connection.send_file/3`). Its final result is
  `:sent` or `:chunked` depending on the response model.

  ## Private fields

  Those fields are reserved for libraries/framework usage.

  * `adapter` - holds the adapter information in a tuple
  * `private` - shared library data as a dict
  """
end

defmodule Plug.Connection do
  @moduledoc """
  Functions for manipulating the connection
  """

  defexception NotSentError, message: "no response was set nor sent from the connection" do
    @moduledoc """
    Error raised when no response is sent in a request
    """
  end

  defexception AlreadySentError, message: "the response was already sent" do
    @moduledoc """
    Error raised when trying to modify or send an already sent response
    """
  end

  alias Plug.Conn
  @already_sent { :plug_conn, :sent }
  @unsent [:unset, :set]

  @doc """
  Assigns a new key and value in the connection.

  ## Examples

      iex> conn.assigns[:hello]
      nil
      iex> conn = assign(conn, :hello, :world)
      iex> conn.assigns[:hello]
      :world

  """
  @spec assign(Conn.t, atom, term) :: Conn.t
  def assign(Conn[assigns: assigns] = conn, key, value) when is_atom(key) do
    conn.assigns(Keyword.put(assigns, key, value))
  end

  @doc """
  Assigns a new private key and value in the connection.

  This storage is meant to be used by libraries and frameworks
  to avoid writing to the user storage (assigns). It is recommended
  for libraries/framework to prefix the keys by the library name.

  For example, if plug some plug needs to store a `:hello` key, it
  should do so as `:plug_hello`:

      iex> conn.private[:plug_hello]
      nil
      iex> conn = assign_private(conn, :plug_hello, :world)
      iex> conn.private[:plug_hello]
      :world

  """
  @spec assign_private(Conn.t, atom, term) :: Conn.t
  def assign_private(Conn[private: private] = conn, key, value) when is_atom(key) do
    conn.private(Keyword.put(private, key, value))
  end

  @doc """
  Sends a response to the client.

  It expects the connection state is to be `:set`,
  otherwise raises ArgumentError for `:unset` connections
  or `Plug.Connection.AlreadySentError` if it was already sent.

  At the end sets the connection state to `:sent`.
  """
  @spec send_resp(Conn.t) :: Conn.t | no_return
  def send_resp(conn)

  def send_resp(Conn[state: :unset]) do
    raise ArgumentError, message: "cannot send a response that was not set"
  end

  def send_resp(Conn[adapter: { adapter, payload }, state: :set] = conn) do
    Conn[] = conn = run_before_send(conn, :set)
    { :ok, body, payload } = adapter.send_resp(payload, conn.status, conn.resp_headers, conn.resp_body)
    send self(), @already_sent
    conn.adapter({ adapter, payload }).resp_body(body).state(:sent)
  end

  def send_resp(Conn[]) do
    raise AlreadySentError
  end

  @doc """
  Sends a file as the response body with the given `status`.

  If available, the file is sent directly over the socket using
  the operating system `sendfile` operation.

  It expects a connection that was not yet `:sent` and sets its
  state to `:sent` afterwards. Otherwise raises
  `Plug.Connection.AlreadySentError`.
  """
  @spec send_file(Conn.t, Conn.status, filename :: binary) :: Conn.t | no_return
  def send_file(Conn[adapter: { adapter, payload }] = conn, status, file)
      when is_integer(status) and is_binary(file) do
    Conn[] = conn = run_before_send(conn.status(status).resp_body(nil), :file)
    { :ok, body, payload } = adapter.send_file(payload, conn.status, conn.resp_headers, file)
    send self(), @already_sent
    conn.adapter({ adapter, payload }).state(:sent).resp_body(body)
  end

  @doc """
  Sends the response headers as a chunked response.

  It expects a connection that was not yet `:sent` and sets its
  state to `:chunked` afterwards. Otherwise raises
  `Plug.Connection.AlreadySentError`.
  """
  @spec send_chunked(Conn.t, Conn.status) :: Conn.t | no_return
  def send_chunked(Conn[adapter: { adapter, payload }, state: state] = conn, status)
      when state in @unsent and is_integer(status) do
    Conn[] = conn = run_before_send(conn.status(status).resp_body(nil), :chunked)
    { :ok, body, payload } = adapter.send_chunked(payload, conn.status, conn.resp_headers)
    send self(), @already_sent
    conn.adapter({ adapter, payload }).resp_body(body)
  end

  def send_chunked(Conn[], status) when is_integer(status) do
    raise AlreadySentError
  end

  @doc """
  Sends a chunk as part of a chunked response.

  It expects a connection with state `:chunked` as set by
  `send_chunked/2`, returns `{ :ok, conn }` in case of success,
  otherwise `{ :error, reason }`.
  """
  @spec chunk(Conn.t, Conn.body) :: { :ok, Conn.t } | { :error, term } | no_return
  def chunk(Conn[adapter: { adapter, payload }, state: :chunked] = conn, chunk) do
    case adapter.chunk(payload, chunk) do
      :ok                    -> { :ok, conn }
      { :ok, body, payload } -> { :ok, conn.resp_body(body).adapter({ adapter, payload }) }
      { :error, _ } = error  -> error
    end
  end

  def chunk(Conn[], chunk) when is_binary(chunk) or is_list(chunk) do
    raise ArgumentError, message: "chunk/2 expects a chunked response. Please ensure " <>
                                  "you have called send_chunked/2 before you send a chunk"
  end

  @doc """
  Sends a response with given status and body.

  See `send_resp/1` for more information.
  """
  @spec send_resp(Conn.t, Conn.status, Conn.body) :: Conn.t | no_return
  def send_resp(Conn[] = conn, status, body) do
    conn |> resp(status, body) |> send_resp()
  end

  @doc """
  Sets the response to given status and body.

  It sets the connection state to `:set` (if not yet `:set`)
  and raises `Plug.Connection.AlreadySentError` if it was already sent.
  """
  @spec resp(Conn.t, Conn.status, Conn.body) :: Conn.t
  def resp(Conn[state: state] = conn, status, body)
      when is_integer(status) and state in @unsent
        and (is_binary(body) or is_list(body)) do
    conn.status(status).resp_body(body).state(:set)
  end

  def resp(Conn[], status, body)
      when is_integer(status) and (is_binary(body) or is_list(body)) do
    raise AlreadySentError
  end

  @doc """
  Puts a new response header.
  Previous entries of the same headers are removed.
  """
  @spec put_resp_header(Conn.t, binary, binary) :: Conn.t
  def put_resp_header(Conn[resp_headers: headers, state: state] = conn, key, value) when
      is_binary(key) and is_binary(value) and state != :sent do
    conn.resp_headers(:lists.keystore(key, 1, headers, { key, value }))
  end

  def put_resp_header(Conn[], key, value) when is_binary(key) and is_binary(value) do
    raise AlreadySentError
  end

  @doc """
  Deletes a response header.
  """
  @spec delete_resp_header(Conn.t, binary) :: Conn.t
  def delete_resp_header(Conn[resp_headers: headers, state: state] = conn, key) when
      is_binary(key) and state != :sent do
    conn.resp_headers(:lists.keydelete(key, 1, headers))
  end

  def delete_resp_header(Conn[], key) when is_binary(key) do
    raise AlreadySentError
  end

  @doc """
  Puts the content-type response header taking into
  account the charset.
  """
  @spec put_resp_content_type(Conn.t, binary, binary | nil) :: Conn.t
  def put_resp_content_type(conn, content_type, charset \\ "utf-8") when
      is_binary(content_type) and (is_binary(charset) or nil?(charset)) do
    value =
      if nil?(charset) do
        content_type
      else
        content_type <> "; charset=" <> charset
      end
    put_resp_header(conn, "content-type", value)
  end

  @doc """
  Fetches parameters from the query string. This function does not
  fetch parameters from the body. To fetch parameters from the body,
  use the `Plug.Parsers` plug.
  """
  @spec fetch_params(Conn.t) :: Conn.t
  def fetch_params(Conn[params: Plug.Connection.Unfetched[], query_string: query_string] = conn) do
    conn.params(Plug.Connection.Query.decode(query_string))
  end

  def fetch_params(Conn[] = conn) do
    conn
  end

  @doc """
  Fetches cookies from the request headers.
  """
  @spec fetch_cookies(Conn.t) :: Conn.t
  def fetch_cookies(Conn[req_cookies: Plug.Connection.Unfetched[],
                         resp_cookies: resp_cookies, req_headers: req_headers] = conn) do
    req_cookies =
      lc { "cookie", cookie } inlist req_headers,
         kv inlist Plug.Connection.Cookies.decode(cookie),
         do: kv

    cookies = Enum.reduce(resp_cookies, req_cookies, fn
      { key, opts }, acc ->
        if value = opts[:value] do
          Dict.put(acc, key, value)
        else
          Dict.delete(acc, key)
        end
    end)

    conn.req_cookies(req_cookies).cookies(cookies)
  end

  def fetch_cookies(Conn[] = conn) do
    conn
  end

  @doc """
  Puts a response cookie.

  ## Options

  * `:domain` - the domain the cookie applies to;
  * `:max_age` - the cookie max-age;
  * `:path` - the path the cookie applies to;
  * `:secure` - if the cookie must be sent only over https;

  """
  @spec put_resp_cookie(Conn.t, binary, binary, Keyword.t) :: Conn.t
  def put_resp_cookie(Conn[resp_cookies: resp_cookies] = conn, key, value, opts \\ []) when
      is_binary(key) and is_binary(value) and is_list(opts) do
    resp_cookies = List.keystore(resp_cookies, key, 0, { key, [{:value, value}|opts] })
    conn.resp_cookies(resp_cookies) |> update_cookies(&Dict.put(&1, key, value))
  end

  @epoch { { 1970, 1, 1 }, { 0, 0, 0 } }

  @doc """
  Deletes a response cookie.

  Deleting a cookie requires the same options as to when the cookie was put.
  Check `put_resp_cookie/4` for more information.
  """
  @spec delete_resp_cookie(Conn.t, binary, Keyword.t) :: Conn.t
  def delete_resp_cookie(Conn[resp_cookies: resp_cookies] = conn, key, opts \\ []) when
      is_binary(key) and is_list(opts) do
    opts = opts |> Keyword.put_new(:universal_time, @epoch) |> Keyword.put_new(:max_age, 0)
    resp_cookies = List.keystore(resp_cookies, key, 0, { key, opts })
    conn.resp_cookies(resp_cookies) |> update_cookies(&Dict.delete(&1, key))
  end

  @doc """
  Fetches session from session store. Will also fetch cookies.
  """
  @spec fetch_session(Conn.t) :: Conn.t
  def fetch_session(conn) do
    if fun = conn.private[:plug_session_fetch] do
      conn |> fetch_cookies |> fun.()
    else
      raise ArgumentError, message: "cannot fetch session without a configured session plug"
    end
  end

  @doc """
  Puts specified value in session for given key.
  """
  @spec put_session(Conn.t, any, any) :: Conn.t
  def put_session(conn, key, value) do
    put_session(conn, &Dict.put(&1, key, value))
  end

  @doc """
  Returns session value for given key.
  """
  @spec get_session(Conn.t, any) :: any
  def get_session(conn, key) do
    session = get_session(conn)
    session[key]
  end

  @doc """
  Deletes session for given key.
  """
  @spec delete_session(Conn.t, any) :: Conn.t
  def delete_session(conn, key) do
    put_session(conn, &Dict.delete(&1, key))
  end

  @doc """
  Configures session.

  ## Options

  * `:renew` - generates a new session id for the cookie;
  * `:drop` - drops the session, a session cookie will not be included in the
              response;
  """
  @spec configure_session(Conn.t, Keyword.t) :: Conn.t
  def configure_session(conn, opts) do
    get_session(conn)

    if opts[:renew] do
      conn = assign_private(conn, :plug_session_info, :renew)
    end

    if opts[:drop] do
      conn = assign_private(conn, :plug_session_info, :drop)
    end

    conn
  end

  @doc """
  Registers a callback to be invoked before the response is sent.

  Callbacks are invoked in the reverse order they are defined (callbacks
  defined first are invoked last).
  """
  @spec register_before_send(Conn.t, (Conn.t -> Conn.t)) :: Conn.t
  def register_before_send(Conn[before_send: before_send, state: state] = conn, callback)
      when is_function(callback, 1) and state in @unsent do
    conn.before_send([callback|before_send])
  end

  def register_before_send(Conn[], callback) when is_function(callback, 1) do
    raise AlreadySentError
  end

  defp run_before_send(Conn[state: state, before_send: before_send] = conn, new) when state in @unsent do
    conn = Conn[state: state] = Enum.reduce before_send, conn.state(new), &(&1.(&2))
    if state != new do
      raise ArgumentError, message: "cannot send/change response from run_before_send callback"
    end
    conn.resp_headers(merge_headers(conn.resp_headers, conn.resp_cookies))
  end

  defp run_before_send(_conn, _new) do
    raise AlreadySentError
  end

  defp merge_headers(headers, cookies) do
    Enum.reduce(cookies, headers, fn { key, opts }, acc ->
      [{ "set-cookie", Plug.Connection.Cookies.encode(key, opts) }|acc]
    end)
  end

  defp update_cookies(Conn[state: state], _fun) when state == :sent,
    do: raise AlreadySentError
  defp update_cookies(Conn[cookies: Unfetched[]] = conn, _fun),
    do: conn
  defp update_cookies(Conn[] = conn, fun),
    do: conn.update_cookies(fun)

  defp get_session(conn) do
    if session = conn.private[:plug_session] do
      session
    else
      raise ArgumentError, message: "session not fetched, call fetch_session/1"
    end
  end

  defp put_session(conn, fun) do
    session = get_session(conn) |> fun.()
    status  = conn.private[:plug_session_info] || :write

    conn
    |> assign_private(:plug_session, session)
    |> assign_private(:plug_session_info, status)
  end
end
