defmodule LovelyMermaid.Timeline do
  @moduledoc """
  `timeline`: periods and their events as a vertical list — one row per
  event, the period named on its first row, ported from lovely-mermaid's
  timeline.ts. Lenient: an unreadable statement is dropped and recorded
  in `warnings`.
  """

  alias LovelyMermaid.{Canvas, Graph, Labels, Parse, Width}

  defmodule Row do
    @moduledoc """
    One `timeline` row: the `period` name, the `event` text, and the
    `section` header it belongs to (nil outside sections).
    """
    defstruct [:period, :event, :section]

    def new(period, event, section),
      do: %__MODULE__{period: period, event: event, section: section}
  end

  @doc "Render a `timeline` source to a canvas, or `nil` when nothing parses."
  @spec render(String.t()) :: {Canvas.t(), map(), [String.t()]} | nil
  def render(src) do
    case parse(src) do
      {:ok, title, rows, warnings} ->
        period_w =
          rows
          |> Enum.map(fn r -> if r.section, do: 0, else: Width.string_width(r.period) end)
          |> Enum.max(fn -> 0 end)

        top = if title == nil, do: 0, else: 1

        width =
          ([if(title == nil, do: 0, else: Width.string_width(title) + 6)] ++
             Enum.map(rows, fn r ->
               if r.section,
                 do: Width.string_width(r.event),
                 else: period_w + 3 + Width.string_width(r.event)
             end))
          |> Enum.max(fn -> 0 end)

        canvas = Canvas.new(width, top + length(rows))

        canvas =
          if title != nil do
            t = " #{title} "
            x = max(0, div(width - Width.string_width(t) - 4, 2))
            canvas = Canvas.draw_text(canvas, "──", x, 0, :edge)
            canvas = Canvas.draw_text(canvas, t, x + 2, 0, :title)
            Canvas.draw_text(canvas, "──", x + 2 + Width.string_width(t), 0, :edge)
          else
            canvas
          end

        canvas =
          Enum.reduce(Stream.with_index(rows), canvas, fn {row, i}, canvas ->
            y = top + i

            if row.section do
              Canvas.draw_text(canvas, row.event, 0, y, :title)
            else
              canvas = Canvas.draw_text(canvas, row.period, 0, y, :text)

              if row.event == "" do
                canvas
              else
                canvas = Canvas.draw_text(canvas, "─", period_w + 1, y, :edge)
                Canvas.draw_text(canvas, row.event, period_w + 3, y, :edge_label)
              end
            end
          end)

        {canvas, %{}, warnings}

      :error ->
        nil
    end
  end

  @doc false
  @spec parse(String.t()) ::
          {:ok, String.t() | nil, [%{period: String.t(), event: String.t(), section: boolean()}],
           [String.t()]}
          | :error
  def parse(src) do
    statements = Parse.statements_of(src)

    if Parse.header_kind(statements) != "timeline" do
      :error
    else
      {title, rows, warnings, truncated, _last_period} =
        Enum.reduce(Enum.drop(statements, 1), {nil, [], [], false, false}, fn st,
                                                                              {title, rows,
                                                                               warnings,
                                                                               truncated,
                                                                               last_period} ->
          cond do
            truncated ->
              {title, rows, warnings, true, last_period}

            length(rows) >= Graph.max_edges() ->
              {title, rows, warnings, true, last_period}

            true ->
              first =
                st
                |> words()
                |> List.first()
                |> then(&if &1, do: Labels.ascii_lower(&1), else: "")

              cond do
                first == "title" ->
                  idx = find_needle(String.downcase(st), "title")

                  {non_empty(String.trim(String.slice(st, (idx + 5)..-1//1))), rows, warnings,
                   false, last_period}

                first == "section" ->
                  idx = find_needle(String.downcase(st), "section")
                  name = String.trim(String.slice(st, (idx + 7)..-1//1))

                  {title, [Row.new("", clean(name), true) | rows], warnings, false, false}

                true ->
                  parts = String.split(st, ":") |> Enum.map(&clean/1)
                  period = List.first(parts) || ""
                  events = Enum.drop(parts, 1)

                  cond do
                    period == "" and events != [] and last_period ->
                      new_rows =
                        Enum.map(events, fn event ->
                          Row.new("", event, false)
                        end)

                      {title, Enum.reverse(new_rows, rows), warnings, false, true}

                    period != "" and events == [] ->
                      {title, [Row.new(period, "", false) | rows], warnings, false, true}

                    period == "" or Enum.any?(events, &(&1 == "")) ->
                      {title, rows, ["dropped, unreadable statement: \"#{st}\"" | warnings],
                       false, last_period}

                    true ->
                      new_rows =
                        events
                        |> Enum.with_index()
                        |> Enum.map(fn {event, i} ->
                          Row.new(if(i == 0, do: period, else: ""), event, false)
                        end)

                      {title, Enum.reverse(new_rows, rows), warnings, false, true}
                  end
              end
          end
        end)

      warnings =
        if truncated,
          do:
            Enum.reverse([
              "diagram truncated: event cap (#{Graph.max_edges()}) reached" | warnings
            ]),
          else: Enum.reverse(warnings)

      if rows == [] do
        :error
      else
        {:ok, title, Enum.reverse(rows), warnings}
      end
    end
  end

  defp find_needle(s, needle) do
    case :binary.match(s, needle) do
      {pos, _len} -> pos
      :nomatch -> 0
    end
  end

  defp clean(s) do
    s
    |> String.trim()
    |> Labels.decode_html_entities()
    |> Labels.fit_label(Labels.max_label())
  end

  defp words(s), do: String.split(s, ~r/\s+/, trim: true)

  defp non_empty(s), do: if(s == "", do: nil, else: s)
end
