defmodule LovelyMermaid.Parse do
  defmodule Shaped do
    @moduledoc false
    defstruct [:shape, :label, :after, :unclosed]
  end

  defmodule Link do
    @moduledoc false
    defstruct [:label, :left, :line, :next, :right]
  end

  @moduledoc """
  Source text to diagram model, ported from grok-mermaid's parse.ts.

  Every `parse_*` returns `nil` when the source is not that kind of
  diagram, or when it exceeds a cap — `render` tries each in turn and
  falls back to a framed copy of the source when they all decline.
  """

  alias LovelyMermaid.{Graph, Labels}

  # ------------------------------------------------------------ statements

  defp flush_statement(cur, out) do
    trimmed = String.trim(cur)
    if trimmed != "", do: out ++ [trimmed], else: out
  end

  @doc """
  Split one source line into statements on `;`, stopping at a `%%`
  comment. Quoted spans are opaque, so a label may contain `;` and `%%`.
  """
  @spec split_statements(String.t()) :: [String.t()]
  def split_statements(line) do
    line |> String.graphemes() |> scan_statements([], "", false)
  end

  defp scan_statements([], out, cur, _in_quotes), do: flush_statement(cur, out)

  defp scan_statements([c | rest], out, cur, in_quotes) do
    cond do
      in_quotes ->
        in_quotes = c != "\""
        scan_statements(rest, out, cur <> c, in_quotes)

      c == "\"" ->
        scan_statements(rest, out, cur <> c, true)

      c == "%" ->
        case rest do
          ["%" | _rest2] -> flush_statement(cur, out)
          _ -> scan_statements(rest, out, cur <> c, false)
        end

      c == ";" ->
        scan_statements(rest, flush_statement(cur, out), "", false)

      true ->
        scan_statements(rest, out, cur <> c, false)
    end
  end

  @doc "Split source into statements, honouring `;` and `%%` comments."
  @spec statements_of(String.t()) :: [String.t()]
  def statements_of(src) do
    lines = Labels.src_lines(src)

    lines
    |> Enum.drop(frontmatter_end(lines))
    |> Enum.flat_map(&split_statements/1)
  end

  @doc """
  Index just past a leading YAML frontmatter block (`---` … `---`), or 0
  when there is none. While the block is still unterminated everything is
  frontmatter, so a streamed diagram stays blank until it closes.
  """
  @spec frontmatter_end([String.t()]) :: non_neg_integer()
  def frontmatter_end(lines) do
    i = Enum.find_index(lines, &(String.trim(&1) != "")) || length(lines)

    if i < length(lines) and String.trim(Enum.at(lines, i)) == "---" do
      after_open = Enum.drop(lines, i + 1)

      case Enum.find_index(after_open, &(String.trim(&1) == "---")) do
        nil -> length(lines)
        j -> i + 2 + j
      end
    else
      0
    end
  end

  @doc """
  Mask of characters inside double quotes, for splitters that must not
  cut quoted spans.
  """
  @spec quote_mask([String.t()]) :: [boolean()]
  def quote_mask(chars) do
    {mask, _in_quotes} =
      Enum.reduce(chars, {[], false}, fn c, {mask, in_quotes} ->
        if c == "\"" do
          {[true | mask], not in_quotes}
        else
          {[in_quotes | mask], in_quotes}
        end
      end)

    Enum.reverse(mask)
  end

  defp at(t, i) when is_tuple(t) and i >= 0 and i < tuple_size(t), do: elem(t, i)
  defp at(_t, _i), do: nil

  defp slice_join(t, start, len) do
    for(i <- start..(start + len - 1)//1, i >= 0 and i < tuple_size(t), do: elem(t, i))
    |> IO.iodata_to_binary()
  end

  defp slice_tail_join(t, start) do
    for(i <- start..(tuple_size(t) - 1)//1, do: elem(t, i))
    |> IO.iodata_to_binary()
  end

  defp first_word(s), do: s |> String.split(~r/\s+/, trim: true) |> List.first() || ""

  defp words(s), do: String.split(s, ~r/\s+/, trim: true)

  @doc """
  Split `head : rest` at the first label colon, skipping `:::` tag runs so
  `A:::hot : desc` keeps its tag with the id. `nil` when there is no colon.
  """
  @spec split_colon(String.t()) :: {String.t(), String.t()} | nil
  def split_colon(s) do
    s |> String.graphemes() |> scan_colon([])
  end

  defp scan_colon([], _acc), do: nil

  defp scan_colon([c | rest], acc) do
    if c != ":" do
      scan_colon(rest, [c | acc])
    else
      {run, rest2} = count_colons(rest, 1)

      if run >= 3 do
        # A `:::` tag run is not a label colon; skip past the whole run.
        scan_colon(rest2, acc)
      else
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), IO.iodata_to_binary(rest2)}
      end
    end
  end

  defp count_colons(chars, n) do
    case chars do
      [":" | rest] -> count_colons(rest, n + 1)
      _ -> {n, chars}
    end
  end

  @doc """
  Strip trailing `:::name` tags from an id token: `A:::hot` → id `A`,
  classes `[hot]`.
  """
  @spec take_tags(String.t()) :: {String.t(), [String.t()]}
  def take_tags(token) do
    parts = String.split(token, ":::")

    case parts do
      [_single] ->
        {token, []}

      ["" | _] ->
        {token, []}

      [id | rest] ->
        {id, rest |> Enum.reject(&(&1 == ""))}
    end
  end

  @doc """
  The `title:` of a leading frontmatter block, or nil. The one frontmatter
  key with terminal meaning — `config` and friends style mermaid's own
  renderers and are deliberately ignored.
  """
  @spec frontmatter_title(String.t()) :: String.t() | nil
  def frontmatter_title(src) do
    lines = Labels.src_lines(src)
    fin = frontmatter_end(lines)

    lines
    |> Enum.take(fin)
    |> Enum.find_value(fn line ->
      case split_once(line, ":") do
        nil ->
          nil

        {key, value} ->
          # Untrimmed on the left: an indented `title:` is nested under some
          # other key, not the diagram's.
          if String.trim_trailing(key) != "title" do
            nil
          else
            t = String.trim(value)

            quoted =
              String.length(t) > 1 and
                ((String.starts_with?(t, "\"") and String.ends_with?(t, "\"")) or
                   (String.starts_with?(t, "'") and String.ends_with?(t, "'")))

            title = if quoted, do: String.slice(t, 1..-2//1), else: t
            title = String.trim(title)
            if title == "", do: nil, else: title
          end
      end
    end)
  end

  @doc "Split on the first occurrence of `sep`, like Rust's `split_once`."
  @spec split_once(String.t(), String.t()) :: {String.t(), String.t()} | nil
  def split_once(s, sep) do
    case :binary.match(s, sep) do
      {i, len} -> {String.slice(s, 0, i), String.slice(s, (i + len)..-1//1)}
      :nomatch -> nil
    end
  end

  @doc """
  Parse the body of a `classDef` statement: `name[,name2] k1:v1,k2:v2`.
  Values are kept verbatim; malformed pairs are skipped.
  """
  @spec parse_class_def(String.t(), LovelyMermaid.Graph.t()) :: LovelyMermaid.Graph.t()
  def parse_class_def(st, graph) do
    rest = String.replace_prefix(st, first_word(st), "") |> String.trim()

    case :binary.match(rest, " ") do
      :nomatch ->
        graph

      {ws, _} ->
        names =
          rest
          |> String.slice(0, ws)
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        props = parse_class_props(String.trim(String.slice(rest, ws..-1//1)))

        if names == [] do
          graph
        else
          class_defs =
            Enum.reduce(names, graph.class_defs, fn name, acc -> Map.put(acc, name, props) end)

          %{graph | class_defs: class_defs}
        end
    end
  end

  defp parse_class_props(body) do
    body
    |> split_top(fn c -> c == "," end)
    |> Enum.reduce(%{}, fn pair, props ->
      case split_once(pair, ":") do
        nil ->
          props

        {k, v} ->
          k = String.trim(k)
          v = String.trim(v)
          if k != "" and v != "", do: Map.put(props, k, v), else: props
      end
    end)
  end

  @doc """
  The body of a `class A,B name` statement → `{ids, names}`. The last
  whitespace-separated token is the name list, everything before it the ids —
  so a space after a comma (`class A, B warn`) still reads as two ids.
  """
  @spec parse_class_assign(String.t()) :: {[String.t()], [String.t()]} | nil
  def parse_class_assign(st) do
    rest = st |> String.replace_prefix(first_word(st), "") |> String.trim()

    case Regex.run(~r/\s\S*$/, rest, return: :index) do
      nil ->
        nil

      [{ws, _len}] ->
        split_ids =
          fn s ->
            s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
          end

        {split_ids.(String.slice(rest, 0, ws)), split_ids.(String.slice(rest, ws..-1//1))}
    end
  end

  @doc """
  `A \"url\" [tooltip]` / `A href \"url\" …` → `{id, url}`. The callback
  forms (`call`/`callback`) return nil — their quoted string is a tooltip.
  """
  @spec parse_href(String.t()) :: {String.t(), String.t()} | nil
  def parse_href(st) do
    rest = st |> String.replace_prefix(first_word(st), "") |> String.trim()

    case words(rest) do
      [] ->
        nil

      [id | rest_words] ->
        second = List.first(rest_words)

        if second in ["call", "callback"] do
          nil
        else
          case Regex.run(~r/"([^"]+)"/, rest) do
            nil -> nil
            [_, url] -> {id, url}
          end
        end
    end
  end

  # Split on separator chars sitting outside double quotes and parentheses,
  # dropping empty segments — the one splitter every grammar shares, so
  # quote rules cannot drift between them.
  defp split_top(s, is_sep) do
    chars = String.graphemes(s)

    {out, cur, _depth, _in_quotes} =
      Enum.reduce(chars, {[], [], 0, false}, fn c, {out, cur, depth, in_quotes} ->
        cond do
          in_quotes ->
            if c == "\"",
              do: {out, [c | cur], depth, false},
              else: {out, [c | cur], depth, true}

          c == "\"" ->
            {out, [c | cur], depth, true}

          c in ["(", "["] ->
            {out, [c | cur], depth + 1, false}

          c in [")", "]"] ->
            {out, [c | cur], max(depth - 1, 0), false}

          is_sep.(c) and depth == 0 ->
            seg = cur |> Enum.reverse() |> IO.iodata_to_binary()
            {if(seg != "", do: [seg | out], else: out), [], 0, false}

          true ->
            {out, [c | cur], depth, false}
        end
      end)

    seg = cur |> Enum.reverse() |> IO.iodata_to_binary()
    out = if seg != "", do: [seg | out], else: out
    Enum.reverse(out)
  end

  @doc "Lowercased header word of the first statement, if it names a known diagram."
  @spec header_kind([String.t()]) :: String.t() | nil
  def header_kind(statements) do
    case List.first(statements) do
      nil ->
        nil

      head ->
        word = first_word(head) |> Labels.ascii_lower()

        if word in [
             "graph",
             "flowchart",
             "sequencediagram",
             "statediagram-v2",
             "statediagram",
             "classdiagram",
             "erdiagram",
             "pie",
             "mindmap",
             "timeline",
             "gitgraph",
             "gitgraph:"
           ] do
          word
        else
          nil
        end
    end
  end

  @doc "What kind of diagram the source declares, or `nil`."
  @spec diagram_kind(String.t()) ::
          :flowchart
          | :state
          | :class
          | :er
          | :sequence
          | :pie
          | :mindmap
          | :timeline
          | :gitgraph
          | nil
  def diagram_kind(src) do
    case header_kind(statements_of(src)) do
      w when w in ["graph", "flowchart"] -> :flowchart
      "sequencediagram" -> :sequence
      w when w in ["statediagram-v2", "statediagram"] -> :state
      "classdiagram" -> :class
      "erdiagram" -> :er
      "pie" -> :pie
      "mindmap" -> :mindmap
      "timeline" -> :timeline
      w when w in ["gitgraph", "gitgraph:"] -> :gitgraph
      _ -> nil
    end
  end

  # -------------------------------------------------------------- flowchart

  @doc "Parse a `graph`/`flowchart` source into a graph model."
  @spec parse_graph(String.t()) :: LovelyMermaid.Graph.t() | nil
  def parse_graph(src) do
    statements = statements_of(src)
    kind = header_kind(statements)

    if kind not in ["graph", "flowchart"] do
      nil
    else
      dir = statements |> List.first() |> words() |> Enum.at(1) || "TB"
      graph = Graph.new(Graph.parse_dir(dir))

      {graph, class_assigns, hrefs} =
        Enum.reduce(Enum.drop(statements, 1), {graph, [], []}, fn st, {graph, assigns, hrefs} ->
          case first_word(st) |> Labels.ascii_lower() do
            "classdef" ->
              {parse_class_def(st, graph), assigns, hrefs}

            "class" ->
              case parse_class_assign(st) do
                nil -> {graph, assigns, hrefs}
                assign -> {graph, [assign | assigns], hrefs}
              end

            "click" ->
              case parse_href(st) do
                nil -> {graph, assigns, hrefs}
                href -> {graph, assigns, [href | hrefs]}
              end

            _ ->
              {parse_statement(st, graph), assigns, hrefs}
          end
        end)

      graph =
        Graph.apply_hrefs(graph, Enum.reverse(hrefs))
        |> Graph.apply_classes(Enum.reverse(class_assigns))

      if graph.over_cap or graph.nodes == [], do: nil, else: graph
    end
  end

  @doc "`subgraph id[Title]`, `subgraph \"Title\"`, or a bare title."
  @spec parse_subgraph_decl(String.t()) :: {String.t(), String.t()}
  def parse_subgraph_decl(rest) do
    if String.starts_with?(rest, "\"") do
      case String.split(String.slice(rest, 1..-1//1), "\"", parts: 2) do
        [label, _] -> {label, Labels.decode_html_entities(label)}
        _ -> {rest, rest}
      end
    else
      case String.split(rest, "[", parts: 2) do
        [id, after_open] ->
          label =
            after_open |> String.replace(~r/\]+$/, "") |> String.trim() |> Labels.clean_label()

          if id != "" and label != "" do
            {String.trim(id), label}
          else
            {rest, rest}
          end

        _ ->
          {rest, rest}
      end
    end
  end

  @doc """
  A chain of `node link node link node ...`, each link fanning out over
  `&`. Parses as far as it can and keeps the prefix; whatever it could
  not read is recorded in `graph.warnings`.
  """
  @spec parse_statement(String.t(), LovelyMermaid.Graph.t()) :: LovelyMermaid.Graph.t()
  def parse_statement(st, graph) do
    case first_word(st) |> Labels.ascii_lower() do
      "subgraph" ->
        parse_subgraph(st, graph)

      "end" ->
        %{graph | cur_group: nil}

      "classdef" ->
        graph

      "class" ->
        graph

      "click" ->
        graph

      w when w in ["style", "linkstyle", "direction"] ->
        graph

      _ ->
        chars = st |> String.graphemes() |> List.to_tuple()

        case parse_node_group(chars, 0, graph) do
          {graph, nil} ->
            warn(graph, "dropped, does not start with a node: \"#{st}\"")

          {graph, {prev, i}} ->
            parse_statement_links(chars, i, prev, graph, st)
        end
    end
  end

  defp parse_subgraph(st, graph) do
    if length(graph.groups) >= Graph.max_groups() or
         graph.subgraph_depth >= Graph.max_group_depth() do
      %{graph | over_cap: true}
    else
      rest = String.trim(String.replace_prefix(st, "subgraph", ""))
      {id, label} = parse_subgraph_decl(rest)
      depth = graph.subgraph_depth + 1
      parent = if graph.groups == [], do: nil, else: length(graph.groups) - 1
      groups = graph.groups ++ [%Graph.Group{id: id, label: label, parent: parent}]
      %{graph | groups: groups, cur_group: depth - 1, subgraph_depth: depth}
    end
  end

  defp warn(graph, msg), do: %{graph | warnings: graph.warnings ++ [msg]}

  defp parse_statement_links(chars, i, prev, graph, st) do
    i = skip_spaces(chars, i)

    if i >= tuple_size(chars) do
      graph
    else
      case parse_link(chars, i) do
        nil ->
          rest = slice_tail_join(chars, i)
          warn(graph, "dropped, expected a link: \"#{rest}\"")

        link ->
          i2 = skip_spaces(chars, link.next)

          case parse_node_group(chars, i2, graph) do
            {graph, nil} ->
              warn(graph, "dropped, link has no target: \"#{st}\"")

            {graph, {target, next}} ->
              {graph, pushed?} = push_edges(graph, prev, target, link)

              if not pushed? do
                graph
              else
                parse_statement_links(chars, next, target, graph, st)
              end
          end
      end
    end
  end

  # `A <-- B` reads right-to-left: swap the endpoints so the arrow that was
  # written on the left becomes a normal forward head.
  defp push_edges(graph, prev, target, link) do
    reversed = link.left == :arrow and link.right != :arrow

    Enum.reduce_while(prev, {graph, true}, fn f, {graph, _} ->
      inner =
        Enum.reduce_while(target, {graph, true}, fn t, {graph, _} ->
          {graph, pushed} =
            Graph.push_edge(graph, %Graph.Edge{
              from: if(reversed, do: t, else: f),
              to: if(reversed, do: f, else: t),
              label: link.label,
              head_to: if(reversed, do: :arrow, else: link.right),
              head_from: if(reversed, do: link.right, else: link.left),
              line: link.line
            })

          if pushed, do: {:cont, {graph, true}}, else: {:halt, {graph, false}}
        end)

      case inner do
        {graph, true} -> {:cont, {graph, true}}
        {graph, false} -> {:halt, {graph, false}}
      end
    end)
  end

  @doc "One or more nodes joined by `&`, which fan out into a cross product."
  @spec parse_node_group(tuple(), non_neg_integer(), LovelyMermaid.Graph.t()) ::
          {LovelyMermaid.Graph.t(), {[non_neg_integer()], non_neg_integer()} | nil}
  def parse_node_group(chars, start, graph) do
    case parse_node(chars, start, graph) do
      {graph, nil} ->
        {graph, nil}

      {graph, {index, next}} ->
        parse_group_links(chars, next, [index], graph)
    end
  end

  defp parse_group_links(chars, i, group, graph) do
    j = skip_spaces(chars, i)

    if at(chars, j) != "&" do
      {graph, {Enum.reverse(group), j}}
    else
      case parse_node(chars, j + 1, graph) do
        {graph, nil} -> {graph, nil}
        {graph, {index, next}} -> parse_group_links(chars, next, [index | group], graph)
      end
    end
  end

  defp skip_spaces(chars, i) do
    Enum.reduce_while(i..(tuple_size(chars) - 1)//1, i, fn _, acc ->
      if at(chars, acc) in [" ", "\t"], do: {:cont, acc + 1}, else: {:halt, acc}
    end)
  end

  defp parse_node(chars, start, graph) do
    i = skip_spaces(chars, start)
    id_start = i

    i =
      Enum.reduce_while(i..(tuple_size(chars) - 1)//1, i, fn _, acc ->
        c = at(chars, acc)
        if c != nil and Labels.is_id_char(c), do: {:cont, acc + 1}, else: {:halt, acc}
      end)

    if i == id_start do
      {graph, nil}
    else
      id = slice_join(chars, id_start, i - id_start)
      shaped = read_shape_at(chars, i)

      graph =
        if shaped.unclosed != nil do
          warn(graph, "node \"#{id}\": label is missing its closing `#{shaped.unclosed}`")
        else
          graph
        end

      case Graph.node_index(graph, id, shaped.label, shaped.shape) do
        {graph, nil} ->
          {graph, nil}

        {graph, index} ->
          # `id:::name` (after any shape) attaches an author class to the node.
          next = shaped.after

          if at(chars, next) == ":" and at(chars, next + 1) == ":" and
               at(chars, next + 2) == ":" do
            k = next + 3

            k =
              Enum.reduce_while(k..(tuple_size(chars) - 1)//1, k, fn _, acc ->
                c = at(chars, acc)

                if c != nil and (Labels.is_id_char(c) or c == "-"),
                  do: {:cont, acc + 1},
                  else: {:halt, acc}
              end)

            # A name never ends in `-`: back off so `A:::x-->B` keeps its link.
            k = while_ends_with_dash(chars, k, next + 3)

            if k > next + 3 do
              name = slice_join(chars, next + 3, k - next - 3)
              {Graph.add_class(graph, index, name), {index, k}}
            else
              {graph, {index, next}}
            end
          else
            {graph, {index, next}}
          end
      end
    end
  end

  defp while_ends_with_dash(chars, k, min) do
    if k > min and at(chars, k - 1) == "-" do
      while_ends_with_dash(chars, k - 1, min)
    else
      k
    end
  end

  defp read_shape_at(chars, i) do
    c = at(chars, i)
    n = at(chars, i + 1)

    cond do
      c == "@" and n == "{" -> read_at_shape(chars, i + 2)
      c == "[" and n == "[" -> read_shape(chars, i + 2, "]]", :rect)
      c == "[" and n == "(" -> read_shape(chars, i + 2, ")]", :round)
      c == "[" -> read_shape(chars, i + 1, "]", :rect)
      c == "(" and n == "(" -> read_shape(chars, i + 2, "))", :round)
      c == "(" and n == "[" -> read_shape(chars, i + 2, "])", :round)
      c == "(" -> read_shape(chars, i + 1, ")", :round)
      c == "{" and n == "{" -> read_shape(chars, i + 2, "}}", :diamond)
      c == "{" -> read_shape(chars, i + 1, "}", :diamond)
      c == ">" -> read_shape(chars, i + 1, "]", :rect)
      true -> %Shaped{shape: :rect, label: nil, after: i}
    end
  end

  # Flowchart v2 shape names that read as something other than a plain box.
  # The terminal has three silhouettes; any name not listed means "some kind
  # of box" and maps to `:rect`, as in the TS reference.
  @at_shapes %{
    "rounded" => :round,
    "stadium" => :round,
    "pill" => :round,
    "terminal" => :round,
    "cyl" => :round,
    "cylinder" => :round,
    "database" => :round,
    "db" => :round,
    "circle" => :round,
    "circ" => :round,
    "sm-circ" => :round,
    "small-circle" => :round,
    "dbl-circ" => :round,
    "double-circle" => :round,
    "fr-circ" => :round,
    "framed-circle" => :round,
    "start" => :round,
    "stop" => :round,
    "event" => :round,
    "delay" => :round,
    "cloud" => :round,
    "bang" => :round,
    "diam" => :diamond,
    "diamond" => :diamond,
    "decision" => :diamond,
    "question" => :diamond,
    "hex" => :diamond,
    "hexagon" => :diamond,
    "prepare" => :diamond
  }

  # The v2 node syntax `id@{shape: cyl, label: "..."}`, cursor past the `@{`.
  # The body is `key: value` pairs split on top-level commas; quoted values
  # may contain commas and `}`. Unknown keys are ignored, unknown shapes
  # draw as a plain box, and a body that never closes reports itself like any
  # unterminated label bracket.
  defp read_at_shape(chars, start) do
    {body, i, closed} = scan_at_shape(chars, start, "", 0, false)

    {shape, label} =
      Enum.reduce(split_at_top(body, ","), {:rect, nil}, fn pair, {shape, label} ->
        case String.split(pair, ":", parts: 2) do
          [k, v] ->
            key = Labels.ascii_lower(String.trim(k))

            cond do
              key == "shape" ->
                {Map.get(@at_shapes, Labels.ascii_lower(String.trim(v)), :rect), label}

              key == "label" ->
                cleaned = Labels.clean_label(v)
                {shape, if(String.trim(cleaned) == "", do: nil, else: cleaned)}

              true ->
                {shape, label}
            end

          _ ->
            {shape, label}
        end
      end)

    if closed do
      %Shaped{shape: shape, label: label, after: i + 1}
    else
      %{shape: shape, label: label, after: tuple_size(chars), unclosed: "}"}
    end
  end

  defp scan_at_shape(chars, i, text, depth, in_quotes) do
    if i >= tuple_size(chars) do
      {text, i, false}
    else
      c = at(chars, i)

      cond do
        in_quotes and c == "\"" ->
          scan_at_shape(chars, i + 1, text <> c, depth, false)

        not in_quotes and c == "\"" ->
          scan_at_shape(chars, i + 1, text <> c, depth, true)

        not in_quotes and c == "{" ->
          scan_at_shape(chars, i + 1, text <> c, depth + 1, false)

        not in_quotes and c == "}" ->
          if depth == 0 do
            {text, i, true}
          else
            scan_at_shape(chars, i + 1, text <> c, depth - 1, false)
          end

        true ->
          scan_at_shape(chars, i + 1, text <> c, depth, in_quotes)
      end
    end
  end

  # Split a v2 body on separators that sit outside quoted runs.
  defp split_at_top(body, sep) do
    {parts, cur, _} =
      Enum.reduce(String.graphemes(body), {[], [], false}, fn c, {parts, cur, in_quotes} ->
        cond do
          in_quotes and c == "\"" ->
            {parts, [c | cur], false}

          not in_quotes and c == "\"" ->
            {parts, [c | cur], true}

          not in_quotes and c == sep ->
            {[cur |> Enum.reverse() |> IO.iodata_to_binary() | parts], [], false}

          true ->
            {parts, [c | cur], in_quotes}
        end
      end)

    [cur |> Enum.reverse() |> IO.iodata_to_binary() | parts] |> Enum.reverse()
  end

  # Read label text up to `closer`. Quoting is decided by the first
  # non-space character: inside a quoted label the closer is ignored until
  # the quote closes, so `A["a] b"]` is one node.
  defp read_shape(chars, start, closer, shape) do
    j = skip_spaces(chars, start)
    quoted = at(chars, j) == "\""
    closer_chars = String.graphemes(closer)
    {text, i, _} = scan_shape(chars, start, quoted, closer_chars, "", false)

    if i < tuple_size(chars) do
      %Shaped{shape: shape, label: Labels.clean_label(text), after: i + length(closer_chars)}
    else
      # Ran off the end still looking for the closer.
      %{shape: shape, label: Labels.clean_label(text), after: tuple_size(chars), unclosed: closer}
    end
  end

  defp scan_shape(chars, i, quoted, closer_chars, text, in_quotes) do
    if i >= tuple_size(chars) do
      {text, i, in_quotes}
    else
      c = at(chars, i)

      cond do
        quoted and c == "\"" ->
          scan_shape(chars, i + 1, quoted, closer_chars, text <> c, not in_quotes)

        not in_quotes and
            slice_join(chars, i, length(closer_chars)) == IO.iodata_to_binary(closer_chars) ->
          {text, i, in_quotes}

        true ->
          scan_shape(chars, i + 1, quoted, closer_chars, text <> c, in_quotes)
      end
    end
  end

  defp is_link_char(c), do: c in ["-", ".", "=", "<", ">"]

  defp scan_link_chars(chars, from) do
    Enum.reduce_while(from..(tuple_size(chars) - 1)//1, from, fn _, acc ->
      c = at(chars, acc)
      if c != nil and is_link_char(c), do: {:cont, acc + 1}, else: {:halt, acc}
    end)
  end

  # --- links ------------------------------------------------------------

  defp parse_link(chars, start) do
    i = skip_spaces(chars, start)

    {left, i} =
      if at(chars, i) in ["o", "x"] and at(chars, i + 1) in ["-", ".", "="] do
        {if(at(chars, i) == "o", do: :circle, else: :cross), i + 1}
      else
        {:none, i}
      end

    op_start = i

    i = scan_link_chars(chars, i)

    if i == op_start do
      nil
    else
      op1 = slice_join(chars, op_start, i - op_start)
      left = if left == :none and String.starts_with?(op1, "<"), do: :arrow, else: left
      line = line_kind(op1)
      {right, i} = right_head(chars, op1, i)

      case pipe_label(chars, i) do
        {label, next} when is_binary(label) ->
          %Link{left: left, right: right, line: line, label: non_empty(label), next: next}

        _ ->
          if right == :none do
            inline_label_link(chars, i, left, line)
          else
            %Link{left: left, right: right, line: line, label: nil, next: i}
          end
      end
    end
  end

  # `-->|text|` label
  defp pipe_label(chars, i) do
    if at(chars, i) == "|" do
      l_start = i + 1

      l_end =
        Enum.reduce_while((i + 1)..(tuple_size(chars) - 1)//1, l_start, fn _, acc ->
          if at(chars, acc) == "|", do: {:halt, acc}, else: {:cont, acc + 1}
        end)

      label = slice_join(chars, l_start, l_end - l_start) |> Labels.clean_label()
      next = if at(chars, l_end) == "|", do: l_end + 1, else: l_end
      {label, next}
    else
      :none
    end
  end

  # `-- text -->` inline label, only when the first operator carried no head
  defp inline_label_link(chars, i, left, line) do
    text_start = skip_spaces(chars, i)

    j =
      Enum.reduce_while(text_start..(tuple_size(chars) - 1)//1, text_start, fn _, acc ->
        c = at(chars, acc)
        if c != nil and not is_link_char(c), do: {:cont, acc + 1}, else: {:halt, acc}
      end)

    if j < tuple_size(chars) and j > text_start and at(chars, j) != "<" do
      text = slice_join(chars, text_start, j - text_start)
      op2_start = j

      j = scan_link_chars(chars, j)

      op2 = slice_join(chars, op2_start, j - op2_start)
      {right, j} = right_head(chars, op2, j)
      line = if line == :solid, do: line_kind(op2), else: line

      %Link{
        left: left,
        right: right,
        line: line,
        label: non_empty(Labels.clean_label(text)),
        next: j
      }
    else
      %Link{left: left, right: :none, line: line, label: nil, next: i}
    end
  end

  defp right_head(chars, op, i) do
    if String.contains?(op, ">") do
      {:arrow, i}
    else
      case trailing_head(chars, i) do
        nil -> {:none, i}
        {h, next} -> {h, next}
      end
    end
  end

  defp non_empty(s), do: if(s == "", do: nil, else: s)

  defp line_kind(op) do
    cond do
      String.contains?(op, "=") -> :thick
      String.contains?(op, ".") -> :dotted
      true -> :solid
    end
  end

  # A trailing `o`/`x` head, only when followed by a statement boundary.
  defp trailing_head(chars, i) do
    head =
      case at(chars, i) do
        "o" -> :circle
        "x" -> :cross
        _ -> nil
      end

    if head == nil do
      nil
    else
      next_char = at(chars, i + 1)

      if next_char in [nil, " ", "\t", "|", "&", ";"] do
        {head, i + 1}
      else
        nil
      end
    end
  end

  # ----------------------------------------------------------------- state

  @doc "Parse a `stateDiagram` source into a graph model."
  @spec parse_state(String.t()) :: LovelyMermaid.Graph.t() | nil
  def parse_state(src) do
    statements = statements_of(src)
    kind = header_kind(statements)

    if kind == nil or not String.starts_with?(kind, "statediagram") do
      nil
    else
      graph = Graph.new()

      {graph, _in_note, assigns} =
        parse_state_statements(Enum.drop(statements, 1), graph, false, [], [])

      graph = Graph.apply_classes(graph, Enum.reverse(assigns))
      if graph.over_cap or graph.nodes == [], do: nil, else: graph
    end
  end

  defp parse_state_statements([], graph, _in_note, assigns, _stack), do: {graph, false, assigns}

  defp parse_state_statements([st | rest], graph, in_note, assigns, stack) do
    if in_note do
      parse_state_statements(rest, graph, Labels.ascii_lower(st) != "end note", assigns, stack)
    else
      first = Labels.ascii_lower(first_word(st))
      first_len = String.length(first_word(st))
      rest_str = st |> String.slice(first_len..-1//1) |> String.trim()

      cond do
        first == "direction" ->
          dir_token =
            case words(st) do
              [_h, d | _] -> d
              _ -> ""
            end

          graph = %{graph | dir: Graph.parse_dir(dir_token)}
          parse_state_statements(rest, graph, false, assigns, stack)

        first == "note" ->
          # A single-line `note ... : text` needs no terminator.
          in_note = not String.contains?(st, ":")
          parse_state_statements(rest, graph, in_note, assigns, stack)

        first == "state" and String.ends_with?(rest_str, "{") ->
          body = rest_str |> String.slice(0..-2//1) |> String.trim()
          named = state_composite_name(body)

          graph =
            if named == nil do
              warn(graph, "dropped, unreadable statement: \"#{st}\"")
            else
              graph
            end

          {id, label} = named || {"anon #{length(graph.groups)}", ""}

          case state_new_group(graph, id, label, graph.cur_group) do
            nil ->
              parse_state_statements(rest, %{graph | over_cap: true}, false, assigns, stack)

            {graph, gi} ->
              graph = %{graph | cur_group: gi}
              parse_state_statements(rest, graph, false, assigns, [{gi, nil} | stack])
          end

        first == "state" ->
          case parse_state_decl(st, graph) do
            nil -> {%{graph | over_cap: true}, false, assigns}
            graph -> parse_state_statements(rest, graph, false, assigns, stack)
          end

        first == "classdef" ->
          parse_state_statements(rest, parse_class_def(st, graph), false, assigns, stack)

        first == "class" ->
          case parse_class_assign(st) do
            nil -> parse_state_statements(rest, graph, false, assigns, stack)
            assign -> parse_state_statements(rest, graph, false, [assign | assigns], stack)
          end

        first in ["hide", "scale"] ->
          parse_state_statements(rest, graph, false, assigns, stack)

        first == "}" ->
          case stack do
            [_top | rest_stack] ->
              graph = %{graph | cur_group: state_scope_of(rest_stack)}
              parse_state_statements(rest, graph, false, assigns, rest_stack)

            [] ->
              parse_state_statements(rest, graph, false, assigns, stack)
          end

        first == "--" ->
          case stack do
            [{base, nil} | rest_stack] ->
              # First region divider: members so far move into region 1, then
              # every divider opens the next unlabelled sibling region.
              case state_new_group(graph, "region #{length(graph.groups)}", "", base) do
                nil ->
                  {%{graph | over_cap: true}, false, assigns}

                {graph, r1} ->
                  graph = %{
                    graph
                    | node_group:
                        Enum.map(graph.node_group, fn g -> if g == base, do: r1, else: g end),
                      groups:
                        graph.groups
                        |> Enum.with_index()
                        |> Enum.map(fn {g, gi} ->
                          if gi != r1 and g.parent == base, do: %{g | parent: r1}, else: g
                        end)
                  }

                  state_open_region(graph, base, rest, assigns, rest_stack)
              end

            [{base, _} | rest_stack] ->
              state_open_region(graph, base, rest, assigns, rest_stack)

            [] ->
              parse_state_statements(rest, graph, false, assigns, stack)
          end

        String.contains?(st, "-->") ->
          case parse_transition(st, graph) do
            nil -> {%{graph | over_cap: true}, false, assigns}
            graph -> parse_state_statements(rest, graph, false, assigns, stack)
          end

        true ->
          case parse_state_desc(st, graph) do
            nil -> {%{graph | over_cap: true}, false, assigns}
            graph -> parse_state_statements(rest, graph, false, assigns, stack)
          end
      end
    end
  end

  # `state X {` / `state "Label" as X {` — the id/label of a composite body.
  defp state_composite_name(body) do
    if String.starts_with?(body, "\"") do
      case String.split(String.slice(body, 1..-1//1), "\"", parts: 2) do
        [label, tail] ->
          tail = String.trim(tail)

          {id, _classes} =
            take_tags(
              if(String.starts_with?(tail, "as"),
                do: String.trim(String.replace_prefix(tail, "as", "")),
                else: label
              )
            )

          if id == "", do: nil, else: {id, Labels.decode_html_entities(label)}

        _ ->
          nil
      end
    else
      {id, _classes} =
        body |> String.split("<<", parts: 2) |> hd() |> String.trim() |> take_tags()

      if id == "" or String.match?(id, ~r/\s/), do: nil, else: {id, id}
    end
  end

  # Open the next unlabelled sibling region of a composite; `rest_stack`
  # keeps the stack entry pointing at the new region.
  defp state_open_region(graph, base, rest, assigns, rest_stack) do
    case state_new_group(graph, "region #{length(graph.groups)}", "", base) do
      nil ->
        {%{graph | over_cap: true}, false, assigns}

      {graph, next} ->
        graph = %{graph | cur_group: next}
        parse_state_statements(rest, graph, false, assigns, [{base, next} | rest_stack])
    end
  end

  defp state_new_group(graph, id, label, parent) do
    if length(graph.groups) >= Graph.max_groups() do
      nil
    else
      groups = graph.groups ++ [%Graph.Group{id: id, label: label, parent: parent}]
      {%{graph | groups: groups}, length(groups) - 1}
    end
  end

  defp state_scope_of(stack) do
    case stack do
      [{base, region} | _] -> region || base
      [] -> nil
    end
  end

  # `state "Label" as id`, `state id <<choice>>`, or `state id {`.
  defp parse_state_decl(st, graph) do
    rest =
      st
      |> String.replace_prefix("state", "")
      |> String.trim()
      |> String.replace(~r/\{$/, "")
      |> String.trim()

    if rest == "", do: graph, else: parse_state_decl_rest(rest, graph)
  end

  defp parse_state_decl_rest(rest, graph) do
    if String.starts_with?(rest, "\"") do
      case String.split(String.slice(rest, 1..-1//1), "\"", parts: 2) do
        [label, after_quote] ->
          rest_after = String.trim(after_quote)

          {id, classes} =
            take_tags(
              if(String.starts_with?(rest_after, "as"),
                do: String.trim(String.replace_prefix(rest_after, "as", "")),
                else: label
              )
            )

          case Graph.node_label(graph, id, Labels.decode_html_entities(label)) do
            {_graph, nil} -> nil
            {graph, idx} -> Enum.reduce(classes, graph, &Graph.add_class(&2, idx, &1))
          end

        _ ->
          nil
      end
    else
      {shape, id, stereotyped} =
        case String.split(rest, "<<", parts: 2) do
          [id, stereo_part] ->
            stereo = stereo_part |> String.replace(~r/>>$/, "") |> String.trim()
            shape = if stereo == "choice", do: :diamond, else: :round
            {shape, String.trim(id), true}

          _ ->
            {:round, rest, false}
        end

      {id, classes} = take_tags(id)

      if id == "" or String.match?(id, ~r/\s/) do
        nil
      else
        case Graph.node_index(graph, id, if(stereotyped, do: id, else: nil), shape) do
          {_graph, nil} -> nil
          {graph, idx} -> Enum.reduce(classes, graph, &Graph.add_class(&2, idx, &1))
        end
      end
    end
  end

  # `A --> B: label`, including chains `A --> B --> C`.
  defp parse_transition(st, graph) do
    case transition_loop(st, graph, nil) do
      {_graph, :error} -> nil
      {graph, _} -> graph
    end
  end

  defp transition_loop(rest, graph, prev) do
    case String.split(rest, "-->", parts: 2) do
      [lhs, rhs] ->
        {from_id, from_classes} =
          lhs
          |> String.trim_trailing()
          |> String.replace(~r/-+$/, "")
          |> String.trim()
          |> take_tags()

        {from, graph} =
          if prev != nil do
            if from_id != "", do: {nil, graph}, else: {prev, graph}
          else
            if from_id == "" do
              {nil, graph}
            else
              case state_endpoint(graph, from_id, true) do
                {graph, nil} -> {nil, graph}
                {graph, f} -> {f, Enum.reduce(from_classes, graph, &Graph.add_class(&2, f, &1))}
              end
            end
          end

        if from == nil do
          {graph, :error}
        else
          next_arrow =
            case String.split(rhs, "-->", parts: 2) do
              [head, _rest] -> String.length(head)
              _ -> -1
            end

          # After the label colon it is all label — mermaid never chains past
          # a label, so an arrow inside one (`: go "x --> y"`) is text, not a
          # link. A `:::` tag run is not a label colon.
          colon = split_colon(rhs)

          label_first =
            colon != nil and (next_arrow == -1 or String.length(elem(colon, 0)) < next_arrow)

          {to_part_raw, label, tail} =
            cond do
              label_first ->
                {elem(colon, 0),
                 if(String.trim(elem(colon, 1)) != "",
                   do: Labels.decode_html_entities(String.trim(elem(colon, 1))),
                   else: nil
                 ), ""}

              next_arrow == -1 ->
                {rhs, nil, ""}

              true ->
                {String.slice(rhs, 0, next_arrow), nil, String.slice(rhs, next_arrow..-1//1)}
            end

          {to_id, to_classes} =
            to_part_raw
            |> String.trim_leading()
            |> String.replace(~r/^>+/, "")
            |> String.trim_trailing()
            |> String.replace(~r/-+$/, "")
            |> String.trim()
            |> take_tags()

          if to_id == "" do
            {graph, :error}
          else
            case state_endpoint(graph, to_id, false) do
              {graph, nil} ->
                {graph, :error}

              {graph, to} ->
                graph = Enum.reduce(to_classes, graph, &Graph.add_class(&2, to, &1))

                {graph, _} =
                  Graph.push_edge(graph, %Graph.Edge{
                    from: from,
                    to: to,
                    label: label,
                    head_to: :arrow,
                    head_from: :none,
                    line: :solid
                  })

                transition_loop(tail, graph, to)
            end
          end
        end

      _ ->
        {graph, :ok}
    end
  end

  # `[*]` is start or end depending on which side of the arrow it sits.
  defp state_endpoint(graph, id, is_source) do
    if id == "[*]" do
      Graph.node_index(graph, if(is_source, do: "[*]start", else: "[*]end"), "●", :round)
    else
      Graph.node_index(graph, id, nil, :round)
    end
  end

  # `id: description`, or a bare state name.
  defp parse_state_desc(st, graph) do
    case String.split(st, ":", parts: 2) do
      [id, desc] ->
        {id, classes} = id |> String.trim() |> take_tags()
        desc = String.trim(desc)

        if id == "" or String.match?(id, ~r/\s/) or desc == "" do
          nil
        else
          case Graph.node_label(graph, id, Labels.decode_html_entities(desc)) do
            {_graph, nil} -> nil
            {graph, idx} -> Enum.reduce(classes, graph, &Graph.add_class(&2, idx, &1))
          end
        end

      _ ->
        if String.match?(st, ~r/\s/) do
          nil
        else
          {id, classes} = take_tags(st)

          case Graph.node_index(graph, id, nil, :round) do
            {_graph, nil} -> nil
            {graph, idx} -> Enum.reduce(classes, graph, &Graph.add_class(&2, idx, &1))
          end
        end
    end
  end

  # ----------------------------------------------------------------- class

  # Relation operators, longest-first so `--|>` wins over `--`.
  @class_ops [
    {"<|--", :triangle, :none, :solid},
    {"--|>", :none, :triangle, :solid},
    {"<|..", :triangle, :none, :dotted},
    {"..|>", :none, :triangle, :dotted},
    {"*--", :diamond_fill, :none, :solid},
    {"--*", :none, :diamond_fill, :solid},
    {"o--", :diamond_open, :none, :solid},
    {"--o", :none, :diamond_open, :solid},
    {"<--", :arrow, :none, :solid},
    {"-->", :none, :arrow, :solid},
    {"<..", :arrow, :none, :dotted},
    {"..>", :none, :arrow, :dotted},
    {"--", :none, :none, :solid},
    {"..", :none, :none, :dotted}
  ]

  @doc "Parse a `classDiagram` source into a graph and class infos."
  @spec parse_class(String.t()) ::
          {LovelyMermaid.Graph.t(), [LovelyMermaid.Graph.class_info()]} | nil
  def parse_class(src) do
    statements = statements_of(src)
    kind = header_kind(statements)

    if kind == nil or not String.starts_with?(kind, "classdiagram") do
      nil
    else
      graph = Graph.new()
      infos = []

      case parse_class_statements(Enum.drop(statements, 1), graph, infos, nil, [], []) do
        nil ->
          nil

        {graph, infos, _, assigns, hrefs} ->
          graph =
            Graph.apply_hrefs(graph, Enum.reverse(hrefs))
            |> Graph.apply_classes(Enum.reverse(assigns))

          if graph.over_cap or graph.nodes == [] do
            nil
          else
            {graph, sync_infos(graph, infos)}
          end
      end
    end
  end

  defp sync_infos(graph, infos) do
    extra = length(graph.nodes) - length(infos)

    if extra <= 0 do
      infos
    else
      infos ++ List.duplicate(Graph.empty_class_info(), extra)
    end
  end

  defp declare_class(graph, infos, name) do
    {id, classes} = take_tags(name)
    {graph, idx} = Graph.node_index(graph, id, nil, :rect)
    graph = Enum.reduce(classes, graph, &Graph.add_class(&2, idx, &1))
    {graph, sync_infos(graph, infos), idx}
  end

  defp parse_class_statements([], graph, infos, cur_class, assigns, hrefs),
    do: {graph, infos, cur_class, assigns, hrefs}

  defp parse_class_statements([st | rest], graph, infos, cur_class, assigns, hrefs) do
    if cur_class != nil do
      if st == "}" do
        parse_class_statements(rest, graph, infos, nil, assigns, hrefs)
      else
        parse_class_statements(
          rest,
          graph,
          List.update_at(infos, cur_class, &push_member(&1, st)),
          cur_class,
          assigns,
          hrefs
        )
      end
    else
      first = Labels.ascii_lower(first_word(st))

      cond do
        first == "direction" ->
          dir_token =
            case words(st) do
              [_h, d | _] -> d
              _ -> ""
            end

          graph = %{graph | dir: Graph.parse_dir(dir_token)}
          parse_class_statements(rest, graph, infos, nil, assigns, hrefs)

        first == "classdef" ->
          parse_class_statements(rest, parse_class_def(st, graph), infos, nil, assigns, hrefs)

        first in ["link", "click"] ->
          case parse_href(st) do
            nil -> parse_class_statements(rest, graph, infos, nil, assigns, hrefs)
            href -> parse_class_statements(rest, graph, infos, nil, assigns, [href | hrefs])
          end

        first == "cssclass" ->
          rest_str =
            st
            |> String.replace_prefix(first_word(st), "")
            |> String.trim()
            |> String.replace("\"", "")

          case parse_class_assign("class " <> rest_str) do
            nil -> parse_class_statements(rest, graph, infos, nil, assigns, hrefs)
            assign -> parse_class_statements(rest, graph, infos, nil, [assign | assigns], hrefs)
          end

        first == "class" ->
          rest_str = String.trim(String.replace_prefix(st, "class", ""))
          open = String.ends_with?(rest_str, "{")
          name = if open, do: String.trim(String.slice(rest_str, 0..-2//1)), else: rest_str

          cond do
            # Class names carry no spaces, so `class A,B warn` is the
            # assignment form, as in flowcharts.
            not open and String.match?(name, ~r/\s/) ->
              case parse_class_assign("class " <> name) do
                nil ->
                  parse_class_statements(rest, graph, infos, nil, assigns, hrefs)

                assign ->
                  parse_class_statements(rest, graph, infos, nil, [assign | assigns], hrefs)
              end

            name == "" or String.match?(name, ~r/\s/) ->
              nil

            true ->
              {graph, infos, idx} = declare_class(graph, infos, name)

              if idx == nil,
                do: nil,
                else:
                  parse_class_statements(
                    rest,
                    graph,
                    infos,
                    if(open, do: idx, else: nil),
                    assigns,
                    hrefs
                  )
          end

        first in ["note", "callback", "style", "namespace", "}"] ->
          parse_class_statements(rest, graph, infos, nil, assigns, hrefs)

        String.starts_with?(st, "<<") ->
          case String.split(String.slice(st, 2..-1//1), ">>", parts: 2) do
            [stereo, rest_name] ->
              name = String.trim(rest_name)

              if name == "" or String.match?(name, ~r/\s/) do
                nil
              else
                {graph, infos, idx} = declare_class(graph, infos, name)

                if idx == nil do
                  nil
                else
                  infos =
                    List.update_at(infos, idx, fn info ->
                      %{info | annotation: String.trim(stereo)}
                    end)

                  parse_class_statements(rest, graph, infos, nil, assigns, hrefs)
                end
              end

            _ ->
              nil
          end

        true ->
          case parse_class_relation(st) do
            nil ->
              case String.split(st, ":", parts: 2) do
                [id, text] ->
                  id = String.trim(id)
                  text = String.trim(text)

                  if id == "" or String.match?(id, ~r/\s/) or text == "" do
                    nil
                  else
                    {graph, infos, idx} = declare_class(graph, infos, id)

                    if idx == nil do
                      nil
                    else
                      infos = List.update_at(infos, idx, fn info -> push_member(info, text) end)
                      parse_class_statements(rest, graph, infos, nil, assigns, hrefs)
                    end
                  end

                _ ->
                  nil
              end

            rel ->
              {graph, f} = Graph.node_index(graph, rel.from, nil, :rect)
              {graph, t} = Graph.node_index(graph, rel.to, nil, :rect)

              if f == nil or t == nil or length(graph.edges) >= Graph.max_edges() do
                nil
              else
                graph = %{
                  graph
                  | edges:
                      graph.edges ++
                        [
                          %Graph.Edge{
                            from: f,
                            to: t,
                            label: rel.label,
                            head_to: rel.head_to,
                            head_from: rel.head_from,
                            line: rel.line
                          }
                        ]
                }

                parse_class_statements(rest, graph, infos, nil, assigns, hrefs)
              end
          end
      end
    end
  end

  @doc "Add a member to the attribute or method compartment, eliding past the cap."
  @spec push_member(LovelyMermaid.Graph.class_info(), String.t()) ::
          LovelyMermaid.Graph.class_info()
  def push_member(info, raw) do
    if String.starts_with?(raw, "<<") do
      case String.split(String.slice(raw, 2..-1//1), ">>", parts: 2) do
        [stereo, _] -> %{info | annotation: String.trim(stereo)}
        _ -> info
      end
    else
      member = Labels.decode_html_entities(Labels.display_generics(String.trim(raw)))
      list = if String.contains?(member, "("), do: info.methods, else: info.attrs

      list =
        cond do
          length(list) < Graph.max_members() -> list ++ [member]
          length(list) == Graph.max_members() -> list ++ ["…"]
          true -> list
        end

      if String.contains?(member, "("), do: %{info | methods: list}, else: %{info | attrs: list}
    end
  end

  defp split_id_text(rest) do
    case String.split(rest, ":", parts: 2) do
      [a, b] ->
        {String.trim(a),
         if(String.trim(b) != "", do: Labels.decode_html_entities(String.trim(b)), else: nil)}

      _ ->
        {String.trim(rest), nil}
    end
  end

  defp parse_class_relation(st) do
    chars = st |> String.graphemes() |> List.to_tuple()
    found = find_class_op(chars)

    if found == nil do
      nil
    else
      {pos, op, head_from, head_to, line} = found
      lhs_raw = slice_join(chars, 0, pos) |> String.trim()
      rhs_raw = slice_tail_join(chars, pos + String.length(op)) |> String.trim()
      {lhs, card_from} = strip_cardinality_suffix(lhs_raw)
      {rhs, card_to} = strip_cardinality_prefix(rhs_raw)

      {to_id, rel_label} = split_id_text(rhs)

      if lhs == "" or to_id == "" or String.match?(lhs, ~r/\s/) or String.match?(to_id, ~r/\s/) do
        nil
      else
        label =
          [card_from, rel_label || "", card_to] |> Enum.reject(&(&1 == "")) |> Enum.join(" ")

        %{
          from: lhs,
          to: to_id,
          head_from: head_from,
          head_to: head_to,
          line: line,
          label: if(label == "", do: nil, else: label)
        }
      end
    end
  end

  defp find_class_op(chars) do
    Enum.reduce_while(0..(tuple_size(chars) - 1), nil, fn pos, _acc ->
      tail = slice_join(chars, pos, min(4, tuple_size(chars) - pos))

      case Enum.find(@class_ops, fn {op, _, _, _} -> String.starts_with?(tail, op) end) do
        nil ->
          {:cont, nil}

        {op, head_from, head_to, line} ->
          prev = if pos > 0, do: at(chars, pos - 1), else: nil
          after_c = at(chars, pos + String.length(op))

          glued_lhs = String.starts_with?(op, "o") and prev != nil and Labels.is_id_char(prev)
          glued_rhs = String.ends_with?(op, "o") and after_c != nil and Labels.is_id_char(after_c)

          if glued_lhs or glued_rhs do
            {:cont, nil}
          else
            {:halt, {pos, op, head_from, head_to, line}}
          end
      end
    end)
  end

  # `Class "1"` — a quoted cardinality trailing the left-hand name.
  defp strip_cardinality_suffix(s) do
    t = String.trim_trailing(s)

    if String.ends_with?(t, "\"") do
      rest = String.slice(t, 0..-2//1)

      case String.split(rest, "\"", parts: 2) do
        [name, card] -> {String.trim_trailing(name), card}
        _ -> {t, ""}
      end
    else
      {t, ""}
    end
  end

  # `"0..*" Class` -- a quoted cardinality prefix on the right-hand name.
  defp strip_cardinality_prefix(s) do
    t = String.trim_leading(s)

    if String.starts_with?(t, "\"") do
      rest = String.slice(t, 1..-1//1)

      case String.split(rest, "\"", parts: 2) do
        [card, after_quote] -> {String.trim_leading(after_quote), card}
        _ -> {t, ""}
      end
    else
      {t, ""}
    end
  end

  # ----------------------------------------------------------------- ER

  @doc "Parse an `erDiagram` source into a graph and entity infos."
  @spec parse_er(String.t()) ::
          {LovelyMermaid.Graph.t(), [LovelyMermaid.Graph.class_info()]} | nil
  def parse_er(src) do
    statements = statements_of(src)
    if header_kind(statements) != "erdiagram", do: nil

    graph = Graph.new()
    infos = []

    case parse_er_statements(Enum.drop(statements, 1), graph, infos, nil) do
      nil ->
        nil

      {graph, infos, _} ->
        if graph.over_cap or graph.nodes == [], do: nil, else: {graph, sync_infos(graph, infos)}
    end
  end

  defp parse_er_statements([], graph, infos, cur), do: {graph, infos, cur}

  defp parse_er_statements([st | rest], graph, infos, cur) do
    if cur != nil do
      if st == "}" do
        parse_er_statements(rest, graph, infos, nil)
      else
        parse_er_statements(
          rest,
          graph,
          List.update_at(infos, cur, &push_er_attribute(&1, st)),
          cur
        )
      end
    else
      case split_er_relationship(st) do
        nil ->
          open = String.ends_with?(st, "{")
          decl = if open, do: String.trim(String.slice(st, 0..-2//1)), else: st

          if decl == "" or not match?([_], words(decl)) do
            nil
          else
            {graph, infos, idx} = er_entity(graph, infos, decl)

            if idx == nil,
              do: nil,
              else: parse_er_statements(rest, graph, infos, if(open, do: idx, else: nil))
          end

        {rel, label} ->
          case words(rel) do
            [f_id, op_str, t_id] ->
              case parse_er_op(op_str) do
                nil ->
                  nil

                op ->
                  {graph, infos, f} = er_entity(graph, infos, f_id)
                  {graph, infos, t} = er_entity(graph, infos, t_id)

                  if f == nil or t == nil or length(graph.edges) >= Graph.max_edges() do
                    nil
                  else
                    rel_label = if label == nil, do: "", else: Labels.clean_label(label)

                    edge_label =
                      [op.card_l, rel_label, op.card_r]
                      |> Enum.reject(&(&1 == ""))
                      |> Enum.join(" ")

                    graph = %{
                      graph
                      | edges:
                          graph.edges ++
                            [
                              %Graph.Edge{
                                from: f,
                                to: t,
                                label: if(edge_label == "", do: nil, else: edge_label),
                                head_to: :none,
                                head_from: :none,
                                line: op.line
                              }
                            ]
                    }

                    parse_er_statements(rest, graph, infos, nil)
                  end
              end
          end
      end
    end
  end

  defp er_entity(graph, infos, token) do
    open_idx =
      case String.split(token, "[", parts: 2) do
        [head, _rest] -> String.length(head)
        _ -> nil
      end

    {graph, idx} =
      if open_idx != nil do
        id = String.slice(token, 0..(open_idx - 1))

        label =
          token
          |> String.slice((open_idx + 1)..-1//1)
          |> String.replace(~r/\]+$/, "")
          |> Labels.clean_label()

        if id == "" or label == "", do: {graph, nil}, else: Graph.node_label(graph, id, label)
      else
        Graph.node_index(graph, token, nil, :rect)
      end

    {graph, sync_infos(graph, infos), idx}
  end

  defp split_er_relationship(st) do
    case String.split(st, ":", parts: 2) do
      [rel, label] ->
        if Enum.any?(words(rel), &(parse_er_op(&1) != nil)) do
          {rel, String.trim(label)}
        else
          nil
        end

      _ ->
        if Enum.any?(words(st), &(parse_er_op(&1) != nil)), do: {st, nil}, else: nil
    end
  end

  # A crow's-foot operator: two cardinality glyphs around `--` or `..`.
  defp parse_er_op(tok) do
    if String.length(tok) != 6 or not ascii?(tok) do
      nil
    else
      mid = String.slice(tok, 2, 2)
      line = if(mid == "--", do: :solid, else: if(mid == "..", do: :dotted, else: nil))

      if line == nil do
        nil
      else
        card_l = er_card(String.slice(tok, 0, 2))
        card_r = er_card(String.slice(tok, 4, 2))

        if card_l == nil or card_r == nil,
          do: nil,
          else: %{card_l: card_l, card_r: card_r, line: line}
      end
    end
  end

  defp ascii?(s), do: s |> String.to_charlist() |> Enum.all?(&(&1 <= 0x7F))

  defp er_card(tok) do
    case tok do
      "|o" -> "0..1"
      "o|" -> "0..1"
      "||" -> "1"
      "}o" -> "0..*"
      "o{" -> "0..*"
      "}|" -> "1..*"
      "|{" -> "1..*"
      _ -> nil
    end
  end

  @doc "ER attributes are `type name`; a trailing quoted comment is dropped."
  def push_er_attribute(info, raw) do
    parts =
      words(raw)
      |> Enum.reduce_while([], fn tok, acc ->
        if String.starts_with?(tok, "\"") do
          {:halt, acc}
        else
          {:cont, [tok | acc]}
        end
      end)
      |> Enum.reverse()

    if parts == [] do
      info
    else
      line = Labels.decode_html_entities(Enum.join(parts, " "))

      cond do
        length(info.attrs) < Graph.max_members() -> %{info | attrs: info.attrs ++ [line]}
        length(info.attrs) == Graph.max_members() -> %{info | attrs: info.attrs ++ ["…"]}
        true -> info
      end
    end
  end

  # ---------------------------------------------------------------- sequence

  @seq_ops [
    {"-->>", true, :arrow},
    {"->>", false, :arrow},
    {"--x", true, :cross},
    {"-x", false, :cross},
    {"--)", true, :arrow},
    {"-)", false, :arrow},
    {"-->", true, :arrow},
    {"->", false, :arrow}
  ]

  # A sequence diagram model (participants and items).
  defmodule Sequence do
    @moduledoc false
    defstruct labels: [], index: %{}, items: []

    @type note_anchor ::
            {:over, non_neg_integer(), non_neg_integer()}
            | {:left, non_neg_integer()}
            | {:right, non_neg_integer()}

    @type item ::
            {:message, non_neg_integer(), non_neg_integer(), String.t() | nil, boolean(), atom()}
            | {:note, note_anchor(), String.t()}
            | {:divider, String.t()}

    @type t :: %__MODULE__{
            labels: [String.t()],
            index: %{String.t() => non_neg_integer()},
            items: [item()]
          }

    # Index of a participant, creating it if new.
    @spec participant(t(), String.t(), String.t() | nil) :: {t(), non_neg_integer() | nil}
    def participant(%__MODULE__{} = seq, id, label) do
      case Map.fetch(seq.index, id) do
        {:ok, existing} ->
          if label != nil do
            {%{seq | labels: List.update_at(seq.labels, existing, fn _ -> label end)}, existing}
          else
            {seq, existing}
          end

        :error ->
          if length(seq.labels) >= LovelyMermaid.Graph.max_nodes() do
            {seq, nil}
          else
            seq = %{
              seq
              | index: Map.put(seq.index, id, length(seq.labels)),
                labels: seq.labels ++ [label || id]
            }

            {seq, length(seq.labels) - 1}
          end
      end
    end
  end

  @doc "Parse a `sequenceDiagram` source."
  @spec parse_sequence(String.t()) :: Sequence.t() | nil
  def parse_sequence(src) do
    statements = statements_of(src)

    if header_kind(statements) != "sequencediagram" do
      nil
    else
      case parse_sequence_statements(Enum.drop(statements, 1), %Sequence{}, false, 0, []) do
        nil -> nil
        {seq, _} -> if seq.labels == [], do: nil, else: seq
      end
    end
  end

  defp parse_sequence_statements([], seq, _autonumber, _msg_count, _blocks), do: {seq, []}

  defp parse_sequence_statements([st | rest], seq, autonumber, msg_count, blocks) do
    first = first_word(st)
    lower = Labels.ascii_lower(first)

    cond do
      lower in ["participant", "actor"] ->
        rest_str = String.trim(String.replace_prefix(st, first, ""))

        if rest_str == "" do
          nil
        else
          {id, label} =
            case String.split(rest_str, " as ", parts: 2) do
              [a, b] -> {String.trim(a), Labels.clean_label(b)}
              _ -> {rest_str, nil}
            end

          case Sequence.participant(seq, id, label) do
            {_seq, nil} -> nil
            {seq, _} -> parse_sequence_statements(rest, seq, autonumber, msg_count, blocks)
          end
        end

      lower == "autonumber" ->
        parse_sequence_statements(rest, seq, true, msg_count, blocks)

      lower in [
        "activate",
        "deactivate",
        "create",
        "destroy",
        "title",
        "acctitle",
        "accdescr",
        "links",
        "link",
        "properties"
      ] ->
        parse_sequence_statements(rest, seq, autonumber, msg_count, blocks)

      lower == "note" ->
        case parse_note_anchor(String.trim(String.replace_prefix(st, first, "")), seq) do
          nil ->
            nil

          {seq, text, anchor} ->
            if length(seq.items) >= LovelyMermaid.Graph.max_edges() do
              nil
            else
              seq = %{seq | items: seq.items ++ [{:note, anchor, text}]}
              parse_sequence_statements(rest, seq, autonumber, msg_count, blocks)
            end
        end

      lower in ["loop", "alt", "opt", "par", "critical", "break", "else", "and", "option"] ->
        seq =
          if lower in ["else", "and", "option"] do
            # A continuation only divides a block that opened one.
            if match?([:open | _], blocks) do
              %{seq | items: seq.items ++ [{:divider, Labels.decode_html_entities(st)}]}
            else
              seq
            end
          else
            %{seq | items: seq.items ++ [{:divider, Labels.decode_html_entities(st)}]}
          end

        if length(seq.items) >= LovelyMermaid.Graph.max_edges() do
          nil
        else
          blocks = if lower in ["else", "and", "option"], do: blocks, else: [:open | blocks]
          parse_sequence_statements(rest, seq, autonumber, msg_count, blocks)
        end

      lower in ["rect", "box"] ->
        parse_sequence_statements(rest, seq, autonumber, msg_count, [:box | blocks])

      lower == "end" ->
        {blocks, seq} =
          case List.last(blocks) do
            :open ->
              if length(seq.items) >= LovelyMermaid.Graph.max_edges() do
                {blocks, seq}
              else
                {tl(blocks), %{seq | items: seq.items ++ [{:divider, "end"}]}}
              end

            _ ->
              {tl(blocks), seq}
          end

        if length(seq.items) >= LovelyMermaid.Graph.max_edges() do
          nil
        else
          parse_sequence_statements(rest, seq, autonumber, msg_count, blocks)
        end

      true ->
        case parse_seq_message(st, seq) do
          nil ->
            nil

          {seq, from, to, text, dashed, head} ->
            text =
              if autonumber do
                "#{msg_count + 1}." <> if(text == nil, do: "", else: " " <> text)
              else
                text
              end

            if length(seq.items) >= LovelyMermaid.Graph.max_edges() do
              nil
            else
              seq = %{seq | items: seq.items ++ [{:message, from, to, text, dashed, head}]}

              parse_sequence_statements(
                rest,
                seq,
                autonumber,
                if(autonumber, do: msg_count + 1, else: msg_count),
                blocks
              )
            end
        end
    end
  end

  defp parse_note_anchor(rest, seq) do
    lower = Labels.ascii_lower(rest)

    kind_and_text =
      cond do
        String.starts_with?(lower, "over ") ->
          {:over, String.slice(rest, String.length("over ")..-1//1)}

        String.starts_with?(lower, "left of ") ->
          {:left, String.slice(rest, String.length("left of ")..-1//1)}

        String.starts_with?(lower, "right of ") ->
          {:right, String.slice(rest, String.length("right of ")..-1//1)}

        true ->
          nil
      end

    {kind, ids_and_text} =
      case kind_and_text do
        nil -> {nil, nil}
        {k, t} -> {k, t}
      end

    if kind == nil or ids_and_text == nil do
      nil
    else
      case String.split(ids_and_text, ":", parts: 2) do
        [ids, text] ->
          text = Labels.decode_html_entities(String.trim(text))

          parts =
            ids
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          if parts == [] do
            nil
          else
            case Sequence.participant(seq, Enum.at(parts, 0), nil) do
              {_seq, nil} ->
                nil

              {seq, a} ->
                if kind != :over do
                  {seq, text, {kind, a}}
                else
                  case Enum.at(parts, 1) do
                    nil ->
                      {seq, text, {:over, a, a}}

                    second ->
                      case Sequence.participant(seq, second, nil) do
                        {_seq, nil} -> nil
                        {seq, s} -> {seq, text, {:over, min(a, s), max(a, s)}}
                      end
                  end
                end
            end
          end

        _ ->
          nil
      end
    end
  end

  defp parse_seq_message(st, seq) do
    chars = st |> String.graphemes() |> List.to_tuple()
    found = find_seq_op(chars)

    if found == nil do
      nil
    else
      {pos, op, dashed, head} = found
      from_id = slice_join(chars, 0, pos) |> String.trim()

      if from_id == "" do
        nil
      else
        rest_str =
          slice_tail_join(chars, pos + String.length(op))
          |> String.trim_leading()
          |> String.replace(~r/^[+-]+/, "")

        {to_id, text} = split_id_text(rest_str)

        if to_id == "" do
          nil
        else
          case Sequence.participant(seq, from_id, nil) do
            {_seq, nil} ->
              nil

            {seq, from} ->
              case Sequence.participant(seq, to_id, nil) do
                {_seq, nil} -> nil
                {seq, to} -> {seq, from, to, text, dashed, head}
              end
          end
        end
      end
    end
  end

  defp find_seq_op(chars) do
    Enum.reduce_while(0..(tuple_size(chars) - 1), nil, fn pos, _acc ->
      tail = slice_join(chars, pos, min(4, tuple_size(chars) - pos))

      case Enum.find(@seq_ops, fn {op, _, _} -> String.starts_with?(tail, op) end) do
        nil -> {:cont, nil}
        {op, dashed, head} -> {:halt, {pos, op, dashed, head}}
      end
    end)
  end
end
