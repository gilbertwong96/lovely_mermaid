defmodule GrokMermaid.Parse do
  @moduledoc """
  Source text to diagram model, ported from grok-mermaid's parse.ts.

  Every `parse_*` returns `nil` when the source is not that kind of
  diagram, or when it exceeds a cap — `render` tries each in turn and
  falls back to a framed copy of the source when they all decline.
  """

  alias GrokMermaid.{Graph, Labels}

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
    chars = String.graphemes(line)
    scan_statements(chars, 0, [], "", false)
  end

  defp scan_statements(chars, i, out, cur, _in_quotes) when i >= length(chars) do
    flush_statement(cur, out)
  end

  defp scan_statements(chars, i, out, cur, in_quotes) do
    c = Enum.at(chars, i)

    cond do
      in_quotes ->
        in_quotes = c != "\""
        scan_statements(chars, i + 1, out, cur <> c, in_quotes)

      c == "\"" ->
        scan_statements(chars, i + 1, out, cur <> c, true)

      c == "%" and Enum.at(chars, i + 1) == "%" ->
        flush_statement(cur, out)

      c == ";" ->
        scan_statements(chars, i + 1, flush_statement(cur, out), "", false)

      true ->
        scan_statements(chars, i + 1, out, cur <> c, false)
    end
  end

  @doc "Split source into statements, honouring `;` and `%%` comments."
  @spec statements_of(String.t()) :: [String.t()]
  def statements_of(src) do
    src
    |> Labels.src_lines()
    |> Enum.flat_map(&split_statements/1)
  end

  defp first_word(s), do: s |> String.split(~r/\s+/, trim: true) |> List.first() || ""

  defp words(s), do: String.split(s, ~r/\s+/, trim: true)

  defp header_kind(statements) do
    case List.first(statements) do
      nil ->
        nil

      head ->
        word = first_word(head)

        if word in [
             "graph",
             "flowchart",
             "sequenceDiagram",
             "stateDiagram-v2",
             "stateDiagram",
             "classDiagram",
             "erDiagram"
           ] do
          word
        else
          nil
        end
    end
  end

  @doc "What kind of diagram the source declares, or `nil`."
  @spec diagram_kind(String.t()) :: :flowchart | :state | :class | :er | :sequence | nil
  def diagram_kind(src) do
    case header_kind(statements_of(src)) do
      w when w in ["graph", "flowchart"] -> :flowchart
      "sequenceDiagram" -> :sequence
      w when w in ["stateDiagram-v2", "stateDiagram"] -> :state
      "classDiagram" -> :class
      "erDiagram" -> :er
      _ -> nil
    end
  end

  # -------------------------------------------------------------- flowchart

  @doc "Parse a `graph`/`flowchart` source into a graph model."
  @spec parse_graph(String.t()) :: GrokMermaid.Graph.t() | nil
  def parse_graph(src) do
    statements = statements_of(src)
    kind = header_kind(statements)

    if kind not in ["graph", "flowchart"] do
      nil
    else
      dir = statements |> List.first() |> words() |> Enum.at(1) || "TB"
      graph = Graph.new(Graph.parse_dir(dir))
      graph = Enum.reduce(Enum.drop(statements, 1), graph, &parse_statement/2)
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
  @spec parse_statement(String.t(), GrokMermaid.Graph.t()) :: GrokMermaid.Graph.t()
  def parse_statement(st, graph) do
    case first_word(st) |> Labels.ascii_lower() do
      "subgraph" ->
        parse_subgraph(st, graph)

      "end" ->
        %{graph | cur_group: nil}

      w when w in ["classdef", "class", "style", "linkstyle", "click", "direction"] ->
        graph

      _ ->
        chars = String.graphemes(st)

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
      groups = graph.groups ++ [%{id: id, label: label, parent: List.last(graph.groups)}]
      %{graph | groups: groups, cur_group: depth - 1, subgraph_depth: depth}
    end
  end

  defp warn(graph, msg), do: %{graph | warnings: graph.warnings ++ [msg]}

  defp parse_statement_links(chars, i, prev, graph, st) do
    i = skip_spaces(chars, i)

    if i >= length(chars) do
      graph
    else
      case parse_link(chars, i) do
        nil ->
          rest = Enum.slice(chars, i..-1//1) |> Enum.join()
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
            Graph.push_edge(graph, %{
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
  @spec parse_node_group([String.t()], non_neg_integer(), GrokMermaid.Graph.t()) ::
          {GrokMermaid.Graph.t(), {[non_neg_integer()], non_neg_integer()} | nil}
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

    if Enum.at(chars, j) != "&" do
      {graph, {group, j}}
    else
      case parse_node(chars, j + 1, graph) do
        {graph, nil} -> {graph, nil}
        {graph, {index, next}} -> parse_group_links(chars, next, group ++ [index], graph)
      end
    end
  end

  defp skip_spaces(chars, i) do
    Enum.reduce_while(i..(length(chars) - 1)//1, i, fn _, acc ->
      if Enum.at(chars, acc) in [" ", "\t"], do: {:cont, acc + 1}, else: {:halt, acc}
    end)
  end

  defp parse_node(chars, start, graph) do
    i = skip_spaces(chars, start)
    id_start = i

    i =
      Enum.reduce_while(i..(length(chars) - 1)//1, i, fn _, acc ->
        c = Enum.at(chars, acc)
        if c != nil and Labels.is_id_char(c), do: {:cont, acc + 1}, else: {:halt, acc}
      end)

    if i == id_start do
      {graph, nil}
    else
      id = Enum.slice(chars, id_start, i - id_start) |> Enum.join()
      shaped = read_shape_at(chars, i)

      graph =
        if shaped[:unclosed] != nil do
          warn(graph, "node \"#{id}\": label is missing its closing `#{shaped.unclosed}`")
        else
          graph
        end

      case Graph.node_index(graph, id, shaped.label, shaped.shape) do
        {graph, nil} -> {graph, nil}
        {graph, index} -> {graph, {index, shaped.after}}
      end
    end
  end

  defp read_shape_at(chars, i) do
    c = Enum.at(chars, i)
    n = Enum.at(chars, i + 1)

    cond do
      c == "[" and n == "[" -> read_shape(chars, i + 2, "]]", :rect)
      c == "[" and n == "(" -> read_shape(chars, i + 2, ")]", :round)
      c == "[" -> read_shape(chars, i + 1, "]", :rect)
      c == "(" and n == "(" -> read_shape(chars, i + 2, "))", :round)
      c == "(" and n == "[" -> read_shape(chars, i + 2, "])", :round)
      c == "(" -> read_shape(chars, i + 1, ")", :round)
      c == "{" and n == "{" -> read_shape(chars, i + 2, "}}", :diamond)
      c == "{" -> read_shape(chars, i + 1, "}", :diamond)
      c == ">" -> read_shape(chars, i + 1, "]", :rect)
      true -> %{shape: :rect, label: nil, after: i}
    end
  end

  # Read label text up to `closer`. Quoting is decided by the first
  # non-space character: inside a quoted label the closer is ignored until
  # the quote closes, so `A["a] b"]` is one node.
  defp read_shape(chars, start, closer, shape) do
    j = skip_spaces(chars, start)
    quoted = Enum.at(chars, j) == "\""
    closer_chars = String.graphemes(closer)
    {text, i, _} = scan_shape(chars, start, quoted, closer_chars, "", false)

    if i < length(chars) do
      %{shape: shape, label: Labels.clean_label(text), after: i + length(closer_chars)}
    else
      # Ran off the end still looking for the closer.
      %{shape: shape, label: Labels.clean_label(text), after: length(chars), unclosed: closer}
    end
  end

  defp scan_shape(chars, i, quoted, closer_chars, text, in_quotes) do
    if i >= length(chars) do
      {text, i, in_quotes}
    else
      c = Enum.at(chars, i)

      cond do
        quoted and c == "\"" ->
          scan_shape(chars, i + 1, quoted, closer_chars, text <> c, not in_quotes)

        not in_quotes and Enum.slice(chars, i, length(closer_chars)) == closer_chars ->
          {text, i, in_quotes}

        true ->
          scan_shape(chars, i + 1, quoted, closer_chars, text <> c, in_quotes)
      end
    end
  end

  defp is_link_char(c), do: c in ["-", ".", "=", "<", ">"]

  # --- links ------------------------------------------------------------

  defp parse_link(chars, start) do
    i = skip_spaces(chars, start)

    {left, i} =
      if Enum.at(chars, i) in ["o", "x"] and Enum.at(chars, i + 1) in ["-", ".", "="] do
        {if(Enum.at(chars, i) == "o", do: :circle, else: :cross), i + 1}
      else
        {:none, i}
      end

    op_start = i

    i =
      Enum.reduce_while(i..(length(chars) - 1)//1, i, fn _, acc ->
        c = Enum.at(chars, acc)
        if c != nil and is_link_char(c), do: {:cont, acc + 1}, else: {:halt, acc}
      end)

    if i == op_start do
      nil
    else
      op1 = Enum.slice(chars, op_start, i - op_start) |> Enum.join()
      left = if left == :none and String.starts_with?(op1, "<"), do: :arrow, else: left
      line = line_kind(op1)
      {right, i} = right_head(chars, op1, i)

      case pipe_label(chars, i) do
        {label, next} when is_binary(label) ->
          %{left: left, right: right, line: line, label: non_empty(label), next: next}

        _ ->
          if right == :none do
            inline_label_link(chars, i, left, line)
          else
            %{left: left, right: right, line: line, label: nil, next: i}
          end
      end
    end
  end

  # `-->|text|` label
  defp pipe_label(chars, i) do
    if Enum.at(chars, i) == "|" do
      l_start = i + 1

      l_end =
        Enum.reduce_while((i + 1)..(length(chars) - 1)//1, l_start, fn _, acc ->
          if Enum.at(chars, acc) == "|", do: {:halt, acc}, else: {:cont, acc + 1}
        end)

      label = Enum.slice(chars, l_start, l_end - l_start) |> Enum.join() |> Labels.clean_label()
      next = if Enum.at(chars, l_end) == "|", do: l_end + 1, else: l_end
      {label, next}
    else
      :none
    end
  end

  # `-- text -->` inline label, only when the first operator carried no head
  defp inline_label_link(chars, i, left, line) do
    text_start = skip_spaces(chars, i)

    j =
      Enum.reduce_while(text_start..(length(chars) - 1)//1, text_start, fn _, acc ->
        c = Enum.at(chars, acc)
        if c != nil and not is_link_char(c), do: {:cont, acc + 1}, else: {:halt, acc}
      end)

    if j < length(chars) and j > text_start and Enum.at(chars, j) != "<" do
      text = Enum.slice(chars, text_start, j - text_start) |> Enum.join()
      op2_start = j

      j =
        Enum.reduce_while(j..(length(chars) - 1)//1, j, fn _, acc ->
          c = Enum.at(chars, acc)
          if c != nil and is_link_char(c), do: {:cont, acc + 1}, else: {:halt, acc}
        end)

      op2 = Enum.slice(chars, op2_start, j - op2_start) |> Enum.join()
      {right, j} = right_head(chars, op2, j)
      line = if line == :solid, do: line_kind(op2), else: line

      %{left: left, right: right, line: line, label: non_empty(Labels.clean_label(text)), next: j}
    else
      %{left: left, right: :none, line: line, label: nil, next: i}
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
      case Enum.at(chars, i) do
        "o" -> :circle
        "x" -> :cross
        _ -> nil
      end

    if head == nil do
      nil
    else
      next_char = Enum.at(chars, i + 1)

      if next_char in [nil, " ", "\t", "|", "&", ";"] do
        {head, i + 1}
      else
        nil
      end
    end
  end
end
