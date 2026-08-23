defmodule GrokMermaid.SourceBox do
  @moduledoc """
  The raw source in a framed box, ported from grok-mermaid's
  source-box.ts. What to show when `render` returns `nil`, or returns art
  too wide for the space at hand.
  """

  alias GrokMermaid.{Labels, Width}

  defp sat(a, b), do: max(0, a - b)

  @doc """
  Frame `src` in a titled box, hard-wrapping its lines to `max_width`
  columns. The result can still exceed `max_width`: the body wraps to
  `max(8, max_width - 4)` and the ` mermaid: <kind> ` title is never
  truncated.
  """
  @spec source_box(String.t(), non_neg_integer() | nil) :: map()
  def source_box(src, max_width \\ nil) do
    src = Labels.strip_controls(src)
    header = src |> String.split(~r/\s+/, trim: true) |> List.first() || "diagram"
    title = " mermaid: " <> header <> " "
    limit = if max_width == nil, do: nil, else: max(8, sat(max_width, 4))

    body =
      src
      |> Labels.src_lines()
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reduce({false, []}, fn l, {started, acc} ->
        if not started and l == "" do
          {false, acc}
        else
          {true, acc ++ chunk_line(l, limit)}
        end
      end)
      |> elem(1)

    content_w =
      [Width.string_width(title) | Enum.map(body, &Width.string_width/1)]
      |> Enum.max(fn -> 0 end)

    inner = content_w + 2
    rule = String.duplicate("─", sat(inner, Width.string_width(title)))

    plain = ["╭" <> title <> rule <> "╮"]

    styled = [
      [{"╭", :border}, {title, :title}, {rule <> "╮", :border}]
    ]

    {plain, styled} =
      Enum.reduce(body, {plain, styled}, fn line, {plain, styled} ->
        pad = String.duplicate(" ", sat(content_w, Width.string_width(line)))
        plain = plain ++ ["│ " <> line <> pad <> " │"]
        styled = styled ++ [[{"│ ", :border}, {line, :text}, {pad <> " │", :border}]]
        {plain, styled}
      end)

    bottom = "╰" <> String.duplicate("-", inner) <> "╯"
    plain = plain ++ [bottom]
    styled = styled ++ [[{bottom, :border}]]

    %{plain: plain, styled: styled, width: inner + 2, warnings: []}
  end

  # Hard-break a line at `limit` columns, never splitting a wide glyph.
  defp chunk_line(line, nil), do: [line]

  defp chunk_line(line, limit) do
    if Width.string_width(line) <= limit do
      [line]
    else
      {out, cur, _} =
        Enum.reduce(Width.measured(line), {[], "", 0}, fn {c, cw}, {out, cur, cur_w} ->
          if cur_w + cw > limit and cur != "" do
            {out ++ [cur], c, cw}
          else
            {out, cur <> c, cur_w + cw}
          end
        end)

      if cur != "", do: out ++ [cur], else: out
    end
  end
end
