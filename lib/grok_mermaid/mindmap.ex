defmodule GrokMermaid.Mindmap do
  @moduledoc """
  `mindmap`: an indentation tree, drawn the way every TUI draws trees
  (`├──`/`└──` guides), ported from grok-mermaid's mindmap.ts. Parses raw
  lines rather than statements — the indentation IS the grammar.
  """

  alias GrokMermaid.{Canvas, Graph, Labels, Parse, Width}

  @doc "Render a `mindmap` source to a canvas, or `nil` when nothing parses."
  @spec render(String.t()) :: {Canvas.t(), [String.t()]} | nil
  def render(src) do
    case parse(src) do
      {:ok, roots, warnings} ->
        rows = walk_rows(roots)

        width =
          rows
          |> Enum.map(fn {prefix, text} ->
            Width.string_width(prefix) + Width.string_width(text)
          end)
          |> Enum.max(fn -> 0 end)

        canvas = Canvas.new(width, length(rows))

        canvas =
          Enum.reduce(Enum.with_index(rows), canvas, fn {{prefix, text}, y}, canvas ->
            canvas = Canvas.draw_text(canvas, prefix, 0, y, :edge)
            Canvas.draw_text(canvas, text, Width.string_width(prefix), y, :text)
          end)

        {canvas, warnings}

      :error ->
        nil
    end
  end

  @doc false
  @spec parse(String.t()) :: {:ok, [map()], [String.t()]} | :error
  def parse(src) do
    lines = Labels.src_lines(src)
    lines = Enum.drop(lines, Parse.frontmatter_end(lines))
    header_at = Enum.find_index(lines, &(String.trim(&1) != ""))

    if header_at == nil or
         String.trim(Enum.at(lines, header_at)) |> Labels.ascii_lower() != "mindmap" do
      :error
    else
      {entries, warnings, truncated} =
        Enum.reduce(
          Enum.drop(lines, header_at + 1),
          {[], [], false},
          fn raw, {entries, warnings, truncated} ->
            no_comment = String.split(raw, "%%", parts: 2) |> hd()

            cond do
              truncated ->
                {entries, warnings, true}

              String.trim(no_comment) == "" ->
                {entries, warnings, false}

              length(entries) >= Graph.max_nodes() ->
                {entries, warnings, true}

              true ->
                indent =
                  String.length(no_comment) - String.length(String.trim_leading(no_comment))

                body = String.trim(no_comment)

                # Decoration lines attach to the previous node and draw nothing.
                if String.starts_with?(body, "::icon") or String.starts_with?(body, ":::") do
                  {entries, warnings, false}
                else
                  text = node_text(body)

                  if text == "" do
                    {entries, warnings ++ ["dropped, unreadable statement: \"#{body}\""], false}
                  else
                    {entries ++ [{indent, Labels.fit_label(text, Labels.wrap_width())}], warnings,
                     false}
                  end
                end
            end
          end
        )

      warnings =
        if truncated,
          do: warnings ++ ["diagram truncated: node cap (#{Graph.max_nodes()}) reached"],
          else: warnings

      roots = build_tree(entries)

      if roots == [] do
        :error
      else
        {:ok, roots, warnings}
      end
    end
  end

  @doc false
  @spec node_text(String.t()) :: String.t()
  def node_text(body) do
    # Shape brackets around a mindmap node all mean "text" in a terminal.
    shapes = [["((", "))"], ["))", "(("], ["(-", "-)"], ["{{", "}}"], ["[", "]"], ["(", ")"]]

    Enum.find_value(shapes, Labels.clean_label(body), fn [open, close] ->
      at = find_needle(body, open)

      if at != -1 and String.ends_with?(body, close) and
           String.length(body) > at + String.length(open) + String.length(close) - 1 do
        body
        |> String.slice(
          at + String.length(open),
          String.length(body) - at - String.length(open) - String.length(close)
        )
        |> Labels.clean_label()
      end
    end)
  end

  # Build the tree from `{indent, text}` entries: a node's children are
  # the following entries with strictly deeper indent, siblings share the
  # same indent.
  defp build_tree(entries) do
    {roots, []} = parse_level(entries, -1)
    roots
  end

  defp parse_level([], _min), do: {[], []}

  defp parse_level([{indent, _} | _] = entries, min) when indent <= min do
    {[], entries}
  end

  defp parse_level([{indent, text} | rest], min) do
    {children, rest} = parse_level(rest, indent)
    node = %{text: text, children: children}
    {siblings, rest} = parse_level(rest, min)
    {[node | siblings], rest}
  end

  defp find_needle(s, needle) do
    case :binary.match(s, needle) do
      {pos, _len} -> pos
      :nomatch -> -1
    end
  end

  defp walk_rows(roots) do
    Enum.reduce(roots, [], fn root, rows ->
      walk(root, "", "", rows)
    end)
  end

  defp walk(node, prefix, child_prefix, rows) do
    rows = rows ++ [{prefix, node.text}]

    Enum.reduce(Enum.with_index(node.children), rows, fn {child, i}, rows ->
      last = i == length(node.children) - 1

      walk(
        child,
        child_prefix <> if(last, do: "└── ", else: "├── "),
        child_prefix <> if(last, do: "    ", else: "│   "),
        rows
      )
    end)
  end
end
