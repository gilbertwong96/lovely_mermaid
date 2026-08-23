defmodule LovelyMermaid.SourceBox do
  @moduledoc """
  The raw source in a framed box, ported from grok-mermaid's
  source-box.ts. What to show when `render` returns `nil`, or returns art
  too wide for the space at hand.
  """

  alias LovelyMermaid.{Art, Labels, Span, Width}

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
          {true, Enum.reverse(chunk_line(l, limit), acc)}
        end
      end)
      |> elem(1)
      |> Enum.reverse()

    content_w =
      [Width.string_width(title) | Enum.map(body, &Width.string_width/1)]
      |> Enum.max(fn -> 0 end)

    inner = content_w + 2
    rule = String.duplicate("─", sat(inner, Width.string_width(title)))

    plain = ["╭" <> title <> rule <> "╮"]

    styled = [
      [
        %Span{text: "╭", role: :border},
        %Span{text: title, role: :title},
        %Span{text: rule <> "╮", role: :border}
      ]
    ]

    {plain, styled} =
      Enum.reduce(body, {plain, styled}, fn line, {plain, styled} ->
        pad = String.duplicate(" ", sat(content_w, Width.string_width(line)))
        plain = [IO.iodata_to_binary(["│ ", line, pad, " │"]) | plain]

        styled =
          [
            [
              %Span{text: "│ ", role: :border},
              %Span{text: line, role: :text},
              %Span{text: IO.iodata_to_binary([pad, " │"]), role: :border}
            ]
            | styled
          ]

        {plain, styled}
      end)

    bottom = "╰" <> String.duplicate("-", inner) <> "╯"
    plain = Enum.reverse(plain, [bottom])
    styled = Enum.reverse(styled, [[%Span{text: bottom, role: :border}]])

    %Art{plain: plain, styled: styled, width: inner + 2, class_defs: %{}, warnings: []}
  end

  # Hard-break a line at `limit` columns, never splitting a wide glyph.
  defp chunk_line(line, nil), do: [line]

  defp chunk_line(line, limit) do
    if Width.string_width(line) <= limit do
      [line]
    else
      {out, cur, _} =
        Enum.reduce(Width.measured(line), {[], [], 0}, fn {c, cw}, {out, cur, cur_w} ->
          if cur_w + cw > limit and cur != [] do
            {[cur |> Enum.reverse() |> IO.iodata_to_binary() | out], [c], cw}
          else
            {out, [c | cur], cur_w + cw}
          end
        end)

      cur_bin = cur |> Enum.reverse() |> IO.iodata_to_binary()
      if cur != [], do: Enum.reverse([cur_bin | out]), else: Enum.reverse(out)
    end
  end
end
