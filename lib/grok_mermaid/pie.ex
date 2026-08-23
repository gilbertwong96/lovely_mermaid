defmodule GrokMermaid.Pie do
  @moduledoc """
  `pie`: proportions as a labelled bar list, ported from grok-mermaid's
  pie.ts. A terminal has no circle worth drawing; bars carry the same
  information in less space. Lenient: an unreadable statement is dropped
  and recorded in `warnings`.
  """

  alias GrokMermaid.{Canvas, Graph, Labels, Parse, Width}

  # Columns of the full-scale bar; eighth blocks refine below one cell.
  @bar_w 20
  @eighths ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

  @doc "Render a `pie` source to a canvas, or `nil` when nothing parses."
  @spec render(String.t()) :: {Canvas.t(), [String.t()]} | nil
  def render(src) do
    case parse(src) do
      {:ok, title, slices, show_data, warnings} ->
        total = Enum.reduce(slices, 0, fn s, acc -> acc + s.value end)

        rows =
          Enum.map(slices, fn s ->
            share = if total == 0, do: 0, else: s.value / total
            pct = String.pad_leading("#{round(share * 100)}%", 4)
            data = if show_data, do: "  (#{s.value})", else: ""
            {s.label, share, pct <> data, s.value}
          end)

        bar_x = label_w(rows) + 2
        suffix_x = bar_x + @bar_w + 1

        width =
          suffix_x +
            (rows
             |> Enum.map(fn {_l, _s, suffix, _v} -> Width.string_width(suffix) end)
             |> Enum.max(fn -> 0 end))

        top = if title == nil, do: 0, else: 1
        canvas = Canvas.new(width, top + length(rows))

        canvas =
          if title != nil do
            Canvas.draw_text(
              canvas,
              title,
              max(0, div(width - Width.string_width(title), 2)),
              0,
              :title
            )
          else
            canvas
          end

        canvas =
          Enum.reduce(Enum.with_index(rows), canvas, fn {{label, share, suffix, value}, i},
                                                        canvas ->
            y = top + i
            canvas = Canvas.draw_text(canvas, label, 0, y, :text)
            eighths = round(share * @bar_w * 8)
            bar = String.duplicate("█", div(eighths, 8)) <> Enum.at(@eighths, rem(eighths, 8))
            # A nonzero slice always shows at least a sliver.
            bar = if bar == "" and value > 0, do: "▏", else: bar
            canvas = Canvas.draw_text(canvas, bar, bar_x, y, :edge)
            # The unfilled remainder is a track, so every bar shows its full scale.
            track = String.duplicate("░", @bar_w - Width.string_width(bar))
            canvas = Canvas.draw_text(canvas, track, bar_x + Width.string_width(bar), y, :border)
            Canvas.draw_text(canvas, suffix, suffix_x, y, :edge_label)
          end)

        {canvas, warnings}

      :error ->
        nil
    end
  end

  defp label_w(rows) do
    rows
    |> Enum.map(fn {label, _s, _suffix, _v} -> Width.string_width(label) end)
    |> Enum.max(fn -> 0 end)
  end

  @doc false
  @spec parse(String.t()) ::
          {:ok, String.t() | nil, [%{label: String.t(), value: number()}], boolean(),
           [String.t()]}
          | :error
  def parse(src) do
    statements = Parse.statements_of(src)

    if Parse.header_kind(statements) != "pie" do
      :error
    else
      head = words(Enum.at(statements, 0))
      show_data = Enum.any?(head, &(Labels.ascii_lower(&1) == "showdata"))

      inline_title =
        case Enum.find_index(head, &(Labels.ascii_lower(&1) == "title")) do
          nil -> -1
          i -> i
        end

      title =
        if inline_title == -1,
          do: nil,
          else: non_empty(Enum.join(Enum.drop(head, inline_title + 1), " "))

      {slices, warnings, truncated, title} =
        Enum.reduce(Enum.drop(statements, 1), {[], [], false, title}, fn st,
                                                                         {slices, warnings,
                                                                          truncated, title} ->
          cond do
            truncated ->
              {slices, warnings, true, title}

            length(slices) >= Graph.max_nodes() ->
              {slices, warnings, true, title}

            true ->
              first =
                st
                |> words()
                |> List.first()
                |> then(&if &1, do: Labels.ascii_lower(&1), else: "")

              if first == "title" do
                idx = find_needle(String.downcase(st), "title")

                {slices, warnings, false,
                 non_empty(String.trim(String.slice(st, (idx + 5)..-1//1)))}
              else
                case parse_slice(st) do
                  nil ->
                    {slices, warnings ++ ["dropped, unreadable statement: \"#{st}\""], false,
                     title}

                  slice ->
                    {slices ++ [slice], warnings, false, title}
                end
              end
          end
        end)

      warnings =
        if truncated,
          do: warnings ++ ["diagram truncated: slice cap (#{Graph.max_nodes()}) reached"],
          else: warnings

      if slices == [] do
        :error
      else
        {:ok, title, slices, show_data, warnings}
      end
    end
  end

  @doc false
  @spec parse_slice(String.t()) :: %{label: String.t(), value: number()} | nil
  def parse_slice(st) do
    chars = String.graphemes(st)
    mask = Parse.quote_mask(chars)

    colon =
      chars
      |> Enum.with_index()
      |> Enum.find_value(fn {c, i} -> if c == ":" and not Enum.at(mask, i), do: i end)

    if colon == nil do
      nil
    else
      label =
        chars
        |> Enum.take(colon)
        |> Enum.join()
        |> Labels.clean_label()
        |> Labels.fit_label(24)

      value =
        chars
        |> Enum.drop(colon + 1)
        |> Enum.join()
        |> String.trim()
        |> parse_number()

      if label == "" or value == nil or value < 0 do
        nil
      else
        %{label: label, value: value}
      end
    end
  end

  defp parse_number(s) do
    case Integer.parse(s) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> nil
        end
    end
  end

  defp find_needle(s, needle) do
    case :binary.match(s, needle) do
      {pos, _len} -> pos
      :nomatch -> 0
    end
  end

  defp words(s), do: String.split(s, ~r/\s+/, trim: true)

  defp non_empty(s), do: if(s == "", do: nil, else: s)
end
