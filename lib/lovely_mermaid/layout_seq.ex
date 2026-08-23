defmodule LovelyMermaid.LayoutSeq do
  @moduledoc """
  Sequence diagram layout, ported from grok-mermaid's layout-seq.ts.

  Participants get one column each, with lifelines running the full height
  and a box repeated at top and bottom. Column gaps are solved from the
  widest thing that has to fit between any two columns — a message label,
  a note, a self-message stub — then items stack down the canvas in source
  order.
  """

  alias LovelyMermaid.{Canvas, Labels, Layout, Width}
  alias LovelyMermaid.Parse.Sequence

  @pad 1
  # Minimum columns between adjacent lifelines.
  @seq_gap 5
  @max_canvas_cells 2_097_152

  defp sat(a, b), do: max(0, a - b)
  defp half(n), do: div(n, 2)

  # Where a note box sits, given the lifeline positions.
  defp note_geometry(xs, anchor, text_w) do
    case anchor do
      {:over, from, to} ->
        xf = elem(xs, from)
        xt = elem(xs, to)
        center = half(xf + xt)
        w = max(xt - xf + 5, text_w + 2 * @pad + 2)
        %{x: sat(center, half(w)), w: w}

      {:left, at} ->
        w = text_w + 2 * @pad + 2
        %{x: sat(elem(xs, at), 2 + w - 1), w: w}

      {:right, at} ->
        %{x: elem(xs, at) + 2, w: text_w + 2 * @pad + 2}
    end
  end

  defp item_text_w(nil), do: 0
  defp item_text_w(text), do: Width.string_width(text)

  @doc "Layout a sequence diagram onto a fresh canvas."
  @spec layout_sequence(Sequence.t()) :: Canvas.t() | nil
  def layout_sequence(seq) do
    n = length(seq.labels)
    labels = seq.labels |> Enum.map(&Labels.fit_label(&1, Labels.wrap_width())) |> List.to_tuple()

    box_w =
      labels
      |> Tuple.to_list()
      |> Enum.map(fn l -> max(1, Width.string_width(l)) + 2 * @pad + 2 end)
      |> List.to_tuple()

    box_h = 3

    gaps =
      0..(max(sat(n, 1), 0) - 1)//1
      |> Enum.map(fn i ->
        max(@seq_gap, ceil(elem(box_w, i) / 2) + ceil(elem(box_w, i + 1) / 2) + 1)
      end)
      |> List.to_tuple()

    reqs =
      Enum.reduce(seq.items, [], fn item, reqs ->
        case item do
          {:message, from, to, text, _dashed, _head} ->
            tw = item_text_w(text)

            cond do
              from != to -> [{min(from, to), max(from, to), max(tw + 2, 4)} | reqs]
              from + 1 < n -> [{from, from + 1, 5 + tw + 2} | reqs]
              true -> reqs
            end

          {:note, anchor, text} ->
            tw = Width.string_width(text)

            case anchor do
              {:over, from, to} when from < to ->
                [{from, to, sat(tw, 1)} | reqs]

              {:over, from, _} ->
                need = ceil((tw + 4) / 2) + 2

                extra =
                  if(from > 0, do: [{from - 1, from, need}], else: []) ++
                    if(from + 1 < n, do: [{from, from + 1, need}], else: [])

                Enum.reverse(extra, reqs)

              {:left, at} ->
                if at > 0, do: [{at - 1, at, tw + 7} | reqs], else: reqs

              {:right, at} ->
                if at + 1 < n, do: [{at, at + 1, tw + 7} | reqs], else: reqs
            end

          _ ->
            reqs
        end
      end)

    # Narrowest spans first, so a wide requirement absorbs what they gave.
    reqs = reqs |> Enum.reverse() |> Enum.sort_by(fn {l, r, _} -> r - l end)

    gaps =
      Enum.reduce(reqs, gaps, fn {l, r, need}, gaps ->
        cur = Enum.reduce(l..(r - 1)//1, 0, fn i, acc -> acc + elem(gaps, i) end)
        if cur < need, do: put_elem(gaps, r - 1, elem(gaps, r - 1) + need - cur), else: gaps
      end)

    xs = build_xs(n, gaps, box_w)

    canvas_w =
      elem(xs, n - 1) + ceil(elem(box_w, n - 1) / 2) + 1

    canvas_w =
      Enum.reduce(seq.items, canvas_w, fn item, w ->
        case item do
          {:message, from, from2, text, _, _} when from == from2 ->
            max(w, elem(xs, from) + 5 + item_text_w(text) + 1)

          {:note, anchor, text} ->
            g = note_geometry(xs, anchor, Width.string_width(text))
            max(w, g.x + g.w + 1)

          {:divider, text} ->
            max(w, Width.string_width(text) + 4)

          _ ->
            w
        end
      end)

    {rows, y} = stack_rows(seq.items, box_h + 1, [])
    rows = List.to_tuple(rows)
    bottom_top = y
    canvas_h = bottom_top + box_h

    if canvas_w * canvas_h > @max_canvas_cells do
      nil
    else
      canvas = Canvas.new(canvas_w, canvas_h)

      # participant boxes at top and bottom
      canvas =
        Enum.reduce(0..(n - 1), canvas, fn i, canvas ->
          box = %{
            x: sat(elem(xs, i), half(elem(box_w, i))),
            y: 0,
            w: elem(box_w, i),
            h: box_h,
            cx: elem(xs, i),
            cy: 1,
            rank: 0
          }

          canvas = Layout.draw_box(canvas, box, [elem(labels, i)], :rect)
          box2 = %{box | y: bottom_top, cy: bottom_top + 1}
          Layout.draw_box(canvas, box2, [elem(labels, i)], :rect)
        end)

      # note boxes
      canvas =
        seq.items
        |> Stream.with_index()
        |> Enum.reduce(canvas, fn {item, k}, canvas ->
          case item do
            {:note, anchor, text} ->
              g = note_geometry(xs, anchor, Width.string_width(text))

              box = %{
                x: g.x,
                y: elem(rows, k),
                w: g.w,
                h: 3,
                cx: g.x + half(g.w),
                cy: elem(rows, k) + 1,
                rank: 0
              }

              Layout.draw_box(canvas, box, [text], :rect)

            _ ->
              canvas
          end
        end)

      # lifelines
      canvas =
        Enum.reduce(Tuple.to_list(xs), canvas, fn x, canvas ->
          canvas
          |> Canvas.junction(x, box_h - 1, 2)
          |> Canvas.seg_v(x, box_h, bottom_top - 1)
          |> Canvas.junction(x, bottom_top, 1)
        end)

      canvas =
        seq.items
        |> Stream.with_index()
        |> Enum.reduce(canvas, fn {item, k}, canvas ->
          r = elem(rows, k)

          case item do
            {:message, from, to, text, dashed, head} ->
              draw_message(canvas, from, to, text, dashed, head, xs, r)

            {:divider, text} ->
              draw_divider(canvas, text, r, canvas_w)

            _ ->
              canvas
          end
        end)

      Canvas.finalize_mask(canvas)
    end
  end

  defp build_xs(n, gaps, box_w) do
    {xs, _} =
      Enum.reduce(0..(n - 1)//1, {[], 0}, fn i, {xs, prev} ->
        x = if i == 0, do: half(elem(box_w, 0)), else: prev + elem(gaps, i - 1)
        {[x | xs], x}
      end)

    xs |> Enum.reverse() |> List.to_tuple()
  end

  defp stack_rows([], y, rows), do: {Enum.reverse(rows), y}

  defp stack_rows([item | rest], y, rows) do
    stack_rows(rest, y + row_height(item), [y | rows])
  end

  defp row_height(item) do
    case item do
      {:note, _, _} -> 4
      {:divider, _} -> 2
      {:message, from, to, _text, _, _} when from == to -> 4
      {:message, _, _, nil, _, _} -> 2
      {:message, _, _, _, _, _} -> 3
    end
  end

  defp draw_message(canvas, from, to, text, dashed, head, xs, r) do
    line_ch = if dashed, do: "╌", else: "─"

    if from == to do
      # A stub that leaves the lifeline and returns two rows down.
      x = elem(xs, from)

      canvas =
        canvas
        |> Canvas.junction(x, r, 8)
        |> Canvas.set(x + 1, r, line_ch, :edge)
        |> Canvas.set(x + 2, r, line_ch, :edge)
        |> Canvas.set(x + 3, r, "╮", :edge)
        |> Canvas.set(x + 3, r + 1, "│", :edge)
        |> Canvas.set(x + 1, r + 2, if(head == :cross, do: "×", else: "◄"), :edge)
        |> Canvas.set(x + 2, r + 2, line_ch, :edge)
        |> Canvas.set(x + 3, r + 2, "╯", :edge)

      if text != nil,
        do: Canvas.draw_text_over_edges(canvas, text, x + 5, r + 1, :text),
        else: canvas
    else
      x0 = elem(xs, from)
      x1 = elem(xs, to)
      rightward = x1 > x0
      arrow_row = if text != nil, do: r + 1, else: r
      lo = min(x0, x1)
      hi = max(x0, x1)

      canvas = Canvas.junction(canvas, x0, arrow_row, if(rightward, do: 8, else: 4))

      canvas =
        Enum.reduce((lo + 1)..(hi - 1)//1, canvas, fn x, canvas ->
          Canvas.set(canvas, x, arrow_row, line_ch, :edge)
        end)

      head_ch = if head == :cross, do: "×", else: if(rightward, do: "▶", else: "◄")

      canvas =
        Canvas.set(canvas, if(rightward, do: x1 - 1, else: x1 + 1), arrow_row, head_ch, :edge)

      if text != nil do
        span = hi - lo - 1
        t = Labels.fit_label(text, max(1, span))
        tx = lo + 1 + half(sat(span, Width.string_width(t)))
        Canvas.draw_text_over_edges(canvas, t, tx, r, :text)
      else
        canvas
      end
    end
  end

  defp draw_divider(canvas, text, r, canvas_w) do
    canvas =
      Enum.reduce(0..(canvas_w - 1), canvas, fn x, canvas ->
        Canvas.set(canvas, x, r, "─", :edge)
      end)

    Canvas.draw_text_over_edges(
      canvas,
      " " <> Labels.fit_label(text, sat(canvas_w, 4)) <> " ",
      2,
      r,
      :edge_label
    )
  end
end
