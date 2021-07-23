defmodule Plug.Router.InvalidSpecError do
  defexception message: "invalid route specification"
end

defmodule Plug.Router.MalformedURIError do
  defexception message: "malformed URI", plug_status: 400
end

defmodule Plug.Router.Utils do
  @moduledoc false

  @doc """
  Decodes path information for dispatching.
  """
  def decode_path_info!(conn) do
    # TODO: Remove rescue as this can't fail from Elixir v1.13
    try do
      Enum.map(conn.path_info, &URI.decode/1)
    rescue
      e in ArgumentError ->
        reason = %Plug.Router.MalformedURIError{message: e.message}
        Plug.Conn.WrapperError.reraise(conn, :error, reason, __STACKTRACE__)
    end
  end

  @doc """
  Converts a given method to its connection representation.

  The request method is stored in the `Plug.Conn` struct as an uppercase string
  (like `"GET"` or `"POST"`). This function converts `method` to that
  representation.

  ## Examples

      iex> Plug.Router.Utils.normalize_method(:get)
      "GET"

  """
  def normalize_method(method) do
    method |> to_string |> String.upcase()
  end

  @doc ~S"""
  Builds the pattern that will be used to match against the request's host
  (provided via the `:host`) option.

  If `host` is `nil`, a wildcard match (`_`) will be returned. If `host` ends
  with a dot, a match like `"host." <> _` will be returned.

  ## Examples

      iex> Plug.Router.Utils.build_host_match(nil)
      {:_, [], Plug.Router.Utils}

      iex> Plug.Router.Utils.build_host_match("foo.com")
      "foo.com"

      iex> "api." |> Plug.Router.Utils.build_host_match() |> Macro.to_string()
      "\"api.\" <> _"

  """
  def build_host_match(host) do
    cond do
      is_nil(host) -> quote do: _
      String.last(host) == "." -> quote do: unquote(host) <> _
      is_binary(host) -> host
    end
  end

  @doc """
  Generates a representation that will match routes that
  can include dynamic segments with path suffix.

  Path suffixes are transformed into guard clauses and joint
  with existing guards.

  If a non-binary spec is given, it is assumed to be
  custom match arguments and they are simply returned.
  """
  def build_path_head(spec, guards, context \\ nil) do
    segments = parse_segments(spec)

    if spec_with_suffix_var?(segments) do
      safe_spec = "/" <> Enum.map_join(segments, "/", &remove_suffix(&1))
      {_vars, match} = build_path_match(safe_spec, context)
      guards = Macro.prewalk(guards, &inject_suffix_value(&1, suffix_vars(segments)))

      {match, build_path_params_match(segments), inject_suffix_guard(segments, guards)}
    else
      {vars, match} = build_path_match(spec, context)
      {match, build_path_params_match(vars), guards}
    end
  end

  defp spec_with_suffix_var?(segments), do: suffix_vars(segments) != []

  defp suffix_vars(segments) do
    Enum.flat_map(segments, fn
      {_prefix, _var, ""} -> []
      {_prefix, ":" <> var, suffix} -> [{String.to_atom(var), suffix}]
      _ -> []
    end)
  end

  # inject matching suffix into guard clause involving suffix identifier
  # e.g. /:id.json when id in ["foo", "bar"]

  defp inject_suffix_value({name, metadata, args} = node, suffix_vars) when is_list(args) do
    case {name, parse_guard_args(args, suffix_vars)} do
      {op, %{var: _} = guard_info} when op in [:==, :!=, :=~, :===, :!==] ->
        inject_suffix_value(name, metadata, guard_info)

      {op, %{var: _} = guard_info} when op in [:in] ->
        inject_suffix_value(name, metadata, guard_info)

      {op, %{var: _}} when op in [:is_binary] ->
        node

      {op, %{var: var}} ->
        raise Plug.Router.InvalidSpecError,
          message:
            "#{inspect(op)} currently is an unsupported guard function for #{inspect(var)} suffix identifier"

      {_, _} ->
        node
    end
  end

  defp inject_suffix_value(node, _suffix_vars), do: node

  defp inject_suffix_value(name, metadata, %{var: var, context: c, suffix: s, value: v})
       when is_binary(v) do
    {name, metadata, [Macro.var(var, c), v <> s]}
  end

  defp inject_suffix_value(name, metadata, %{var: var, context: c, suffix: s, value: v}) do
    {name, metadata, [Macro.var(var, c), Enum.map(v, &(&1 <> s))]}
  end

  # Parses guard ast and returns a map representation
  # that provides function/op name, var, suffix, value
  # for injecting suffix value

  defp parse_guard_args(args, suffix_vars) do
    Enum.reduce(args, %{}, fn arg, acc ->
      case arg do
        {var, _metadata, context} when is_nil(context) or is_atom(context) ->
          if Keyword.has_key?(suffix_vars, var) do
            acc
            |> Map.update(:var, var, & &1)
            |> Map.update(:context, context, & &1)
            |> Map.update(:suffix, Keyword.get(suffix_vars, var), & &1)
          else
            acc
          end

        value when is_binary(value) ->
          Map.update(acc, :value, value, & &1)

        value ->
          Map.update(acc, :value, List.wrap(value), &(&1 ++ value))
      end
    end)
  end

  @doc """
  Generates a representation that will only match routes
  according to the given `spec`.

  If a non-binary spec is given, it is assumed to be
  custom match arguments and they are simply returned.

  ## Examples

      iex> Plug.Router.Utils.build_path_match("/foo/:id")
      {[:id], ["foo", {:id, [], nil}]}

  """
  def build_path_match(spec, context \\ nil) when is_binary(spec) do
    build_path_match(split(spec), context, [], [])
  end

  @doc """
  Builds a list of path param names and var match pairs that can bind
  to dynamic path segment values. Excludes params with underscores;
  otherwise, the compiler will warn about used underscored variables
  when they are unquoted in the macro.

  This function also builds var match pairs from parsed segments
  representation that consists of path prefix, var, suffix. It strips
  suffix from dynamic segment values in accordance with Plug DSL design.

  ## Examples

      iex> Plug.Router.Utils.build_path_params_match([:id])
      [{"id", {:id, [], nil}}]

      iex> Plug.Router.Utils.build_path_params_match(["foo", {"bat-", ":bar", ".json"}])
      [
        {
          "bar",
          {
            {:., [], [{:__aliases__, [alias: false], [:String]}, :trim_trailing]}, [],[{:bar, [], nil}, ".json"]
          }
        }
      ]
  """
  def build_path_params_match(vars) when is_list(vars) do
    vars
    |> Enum.flat_map(&build_path_params_match(&1))
    |> Enum.reject(&match?({"_" <> _var, _macro}, &1))
  end

  def build_path_params_match(id) when is_atom(id) do
    [{Atom.to_string(id), Macro.var(id, nil)}]
  end

  def build_path_params_match({_prefix, ":" <> id, _suffix = ""}) do
    [{id, Macro.var(String.to_atom(id), nil)}]
  end

  def build_path_params_match({_prefix, ":" <> id, suffix}) do
    [
      {
        id,
        quote(
          do: String.trim_trailing(unquote(Macro.var(String.to_atom(id), nil)), unquote(suffix))
        )
      }
    ]
  end

  def build_path_params_match(_), do: []

  @doc """
  Builds a list of path prefix, id, suffix representation that can be
  used to transform paths and generate guard clauses for suffix matching.

  ## Examples

      iex> Plug.Router.Utils.parse_segments("/foo/:bar.json")
      ["foo", {"", ":bar", ".json"}]

      iex> Plug.Router.Utils.parse_segments("/foo/:bar")
      ["foo", {"", ":bar", ""}]

      iex> Plug.Router.Utils.parse_segments("/foo/:bar_baz")
      ["foo", {"", ":bar_baz", ""}]

      iex> Plug.Router.Utils.parse_segments("/foo/:bar-json")
      ["foo", {"", ":bar", "-json"}]

      iex> Plug.Router.Utils.parse_segments("/foo/:bar@example.com")
      ["foo", {"", ":bar", "@example.com"}]

      iex> Plug.Router.Utils.parse_segments("/foo/:bar.js.map")
      ["foo", {"", ":bar", ".js.map"}]

      iex> Plug.Router.Utils.parse_segments("/foo/bat-:bar.json")
      ["foo", {"bat-", ":bar", ".json"}]

      iex> Plug.Router.Utils.parse_segments("/foo/bat-:id.app/baz/:bar.json")
      ["foo", {"bat-", ":id", ".app"}, "baz", {"", ":bar", ".json"}]
  """
  def parse_segments(path) when is_binary(path) do
    Enum.map(split(path), fn segment ->
      case Regex.run(~r/([^:]*):(.*?)([^a-zA-Z_].*)?$/, segment, capture: :all_but_first) do
        nil ->
          segment

        [prefix, id] ->
          {prefix, ":" <> id, ""}

        [_prefix, _id, <<_::binary-size(1), ?:, rest::binary>>] ->
          raise Plug.Router.InvalidSpecError, message: "dynamic suffix (:#{rest}) is unsupported"

        [prefix, id, suffix] ->
          if String.contains?(suffix, ":") do
            raise Plug.Router.InvalidSpecError, message: "invalid character \":\" in suffix"
          else
            {prefix, ":" <> id, suffix}
          end
      end
    end)
  end

  @doc """
  Rebinds variables and removes any suffix from dynamic segment values
  by using the params var match pairs.
  """
  def rebind_vars(params_match) do
    for {id, ast} <- params_match do
      quote(do: unquote(Macro.var(String.to_atom(id), nil)) = unquote(ast))
    end
  end

  @doc """
  Renders dynamic segment by removing suffix from a segment representation.
  Dynamic segment suffix is transformed internally by Plug into guard clauses.

  ## Examples

      iex> Plug.Router.Utils.remove_suffix("foo")
      "foo"

      iex> Plug.Router.Utils.remove_suffix(":foo")
      ":foo"

      iex> Plug.Router.Utils.remove_suffix(":foo_json")
      ":foo_json"

      iex> Plug.Router.Utils.remove_suffix({"foo-", ":bar", ".json"})
      "foo-:bar"

      iex> Plug.Router.Utils.remove_suffix({"", ":foo", ".json"})
      ":foo"

      iex> Plug.Router.Utils.remove_suffix({"", ":foo", ".js.map"})
      ":foo"
  """
  def remove_suffix({prefix, identifier, _suffix}), do: prefix <> identifier
  def remove_suffix(segment), do: segment

  @doc """
  Splits the given path into several segments.
  It ignores both leading and trailing slashes in the path.

  ## Examples

      iex> Plug.Router.Utils.split("/foo/bar")
      ["foo", "bar"]

      iex> Plug.Router.Utils.split("/:id/*")
      [":id", "*"]

      iex> Plug.Router.Utils.split("/foo//*_bar")
      ["foo", "*_bar"]

  """
  def split(bin) do
    for segment <- String.split(bin, "/"), segment != "", do: segment
  end

  @deprecated "Use Plug.forward/4 instead"
  defdelegate forward(conn, new_path, target, opts), to: Plug

  ## Helpers

  # Loops each segment checking for matches.

  defp build_path_match([h | t], context, vars, acc) do
    handle_segment_match(segment_match(h, "", context), t, context, vars, acc)
  end

  defp build_path_match([], _context, vars, acc) do
    {vars |> Enum.uniq() |> Enum.reverse(), Enum.reverse(acc)}
  end

  # Handle each segment match. They can either be a
  # :literal ("foo"), an :identifier (":bar") or a :glob ("*path")

  defp handle_segment_match({:literal, literal}, t, context, vars, acc) do
    build_path_match(t, context, vars, [literal | acc])
  end

  defp handle_segment_match({:identifier, identifier, expr}, t, context, vars, acc) do
    build_path_match(t, context, [identifier | vars], [expr | acc])
  end

  defp handle_segment_match({:glob, _identifier, _expr}, t, _context, _vars, _acc) when t != [] do
    raise Plug.Router.InvalidSpecError, message: "cannot have a *glob followed by other segments"
  end

  defp handle_segment_match({:glob, identifier, expr}, _t, context, vars, [hs | ts]) do
    acc = [{:|, [], [hs, expr]} | ts]
    build_path_match([], context, [identifier | vars], acc)
  end

  defp handle_segment_match({:glob, identifier, expr}, _t, context, vars, _) do
    {vars, expr} = build_path_match([], context, [identifier | vars], [expr])
    {vars, hd(expr)}
  end

  # In a given segment, checks if there is a match.

  defp segment_match(":" <> argument, buffer, context) do
    identifier = binary_to_identifier(":", argument)

    expr =
      quote_if_buffer(identifier, buffer, context, fn var ->
        quote do: unquote(buffer) <> unquote(var)
      end)

    {:identifier, identifier, expr}
  end

  defp segment_match("*" <> argument, buffer, context) do
    underscore = {:_, [], context}
    identifier = binary_to_identifier("*", argument)

    expr =
      quote_if_buffer(identifier, buffer, context, fn var ->
        quote do: [unquote(buffer) <> unquote(underscore) | unquote(underscore)] = unquote(var)
      end)

    {:glob, identifier, expr}
  end

  defp segment_match(<<h, t::binary>>, buffer, context) do
    segment_match(t, buffer <> <<h>>, context)
  end

  defp segment_match(<<>>, buffer, _context) do
    {:literal, buffer}
  end

  defp quote_if_buffer(identifier, "", context, _fun) do
    {identifier, [], context}
  end

  defp quote_if_buffer(identifier, _buffer, context, fun) do
    fun.({identifier, [], context})
  end

  defp binary_to_identifier(prefix, <<letter, _::binary>> = binary)
       when letter in ?a..?z or letter == ?_ do
    if binary =~ ~r/^\w+$/ do
      String.to_atom(binary)
    else
      raise Plug.Router.InvalidSpecError,
        message: "#{prefix}identifier in routes must be made of letters, numbers and underscores"
    end
  end

  defp binary_to_identifier(prefix, _) do
    raise Plug.Router.InvalidSpecError,
      message: "#{prefix} in routes must be followed by lowercase letters or underscore"
  end

  defp inject_suffix_guard(segments, guards) do
    suffix_guards = Enum.map(segments, &build_suffix_guard/1) |> Enum.reject(&is_nil/1)

    case suffix_guards do
      [suffix_guard] ->
        join_guards(suffix_guard, guards)

      suffix_guards ->
        Enum.reduce(tl(suffix_guards), hd(suffix_guards), fn guard, acc ->
          quote(do: unquote(acc) and unquote(guard))
        end)
        |> join_guards(guards)
    end
  end

  defp build_suffix_guard({_prefix, _identifier, _suffix = ""}), do: nil

  defp build_suffix_guard({_prefix, ":" <> identifier, suffix}) do
    var = Macro.var(String.to_atom(identifier), nil)

    quote do
      binary_part(
        unquote(var),
        byte_size(unquote(var)) - byte_size(unquote(suffix)),
        byte_size(unquote(suffix))
      ) == unquote(suffix)
    end
  end

  defp build_suffix_guard(_), do: nil

  defp join_guards(fst, true), do: fst
  defp join_guards(fst, snd), do: quote(do: unquote(fst) and unquote(snd))
end
