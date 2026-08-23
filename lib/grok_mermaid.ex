defmodule GrokMermaid do
  @moduledoc """
  Render a Mermaid source block as Unicode box-drawing art for the
  terminal, mirroring pi's grok-mermaid transformer.

  Supported: `graph`/`flowchart` (including `subgraph`), `stateDiagram`,
  `classDiagram`, `erDiagram` and `sequenceDiagram`.

  The diagram is laid out at whatever size it needs; `art.width` reports
  the columns that turned out to be. Deciding what to do when that exceeds
  the space at hand is the caller's — `GrokMermaid.SourceBox.source_box/2`
  is the usual answer:

      art = GrokMermaid.render(src)
      show(art && art.width <= cols ? art : source_box(src, cols))

  `nil` means there is no art to show: blank input, a syntax error, a
  diagram type this renderer does not draw, or one large enough that
  laying it out is refused. `diagram_kind/1` separates the middle two.

  Rendering is best-effort. A flowchart keeps whatever parsed; the
  stricter grammars additionally get one retry without their final line,
  which keeps a streaming diagram on screen while its last statement is
  half-typed. Everything given up on is listed in `art.warnings` —
  advisory only, never a reason to withhold the art.
  """

  alias GrokMermaid.{Canvas, Labels, Layout, LayoutSeq, Parse}

  @doc """
  Renders a Mermaid source to Unicode art.

  Returns `%{plain: [String.t()], styled: [[{String.t(), atom()}]], width: non_neg_integer(), warnings: [String.t()]}`
  or `nil` when there is nothing to draw.
  """
  @spec render(String.t()) :: map() | nil
  def render(src) when is_binary(src) do
    src = Labels.strip_controls(src)

    if String.trim(src) == "" do
      nil
    else
      case attempt(src) do
        nil -> nil
        {canvas, warnings} -> canvas_to_art(canvas, warnings)
      end
    end
  end

  def render(_), do: nil

  @doc "What kind of diagram the source declares, or `nil`."
  @spec diagram_kind(String.t()) :: atom() | nil
  def diagram_kind(src), do: Parse.diagram_kind(src)

  defp canvas_to_art(canvas, warnings) do
    {plain, styled, width} = Canvas.to_lines(canvas)
    %{plain: plain, styled: styled, width: width, warnings: warnings}
  end

  # Draw `src`, retrying once without its last line if the grammar rejects
  # it, so a streaming source stays on screen while its final statement is
  # half-typed.
  defp attempt(src) do
    case draw(src) do
      nil ->
        body = String.replace(src, ~r/\s+$/, "")

        case String.split(body, "\n") do
          [_single] ->
            nil

          lines ->
            salvaged = lines |> Enum.drop(-1) |> Enum.join("\n")

            case draw(salvaged) do
              nil ->
                nil

              {canvas, warnings} ->
                dropped = lines |> List.last() |> String.trim()
                {canvas, warnings ++ ["dropped, unreadable final line: \"#{dropped}\""]}
            end
        end

      drawn ->
        drawn
    end
  end

  defp draw(src) do
    case Parse.diagram_kind(src) do
      :flowchart ->
        case Parse.parse_graph(src) do
          nil -> nil
          graph -> draw_graph(graph, :flowchart)
        end

      :state ->
        case Parse.parse_state(src) do
          nil -> nil
          graph -> draw_graph(graph, :flowchart)
        end

      :class ->
        case Parse.parse_class(src) do
          nil -> nil
          {graph, infos} -> draw_class(graph, infos)
        end

      :er ->
        case Parse.parse_er(src) do
          nil -> nil
          {graph, infos} -> draw_class(graph, infos)
        end

      :sequence ->
        case Parse.parse_sequence(src) do
          nil -> nil
          seq -> draw_sequence(seq)
        end

      nil ->
        nil
    end
  end

  defp draw_graph(graph, _kind) do
    canvas =
      if graph.groups == [] do
        Layout.layout_flowchart(graph)
      else
        Layout.layout_grouped(graph)
      end

    if canvas, do: {canvas, graph.warnings}, else: nil
  end

  defp draw_class(graph, infos) do
    canvas = Layout.layout_class(graph, infos)
    if canvas, do: {canvas, []}, else: nil
  end

  defp draw_sequence(seq) do
    case LayoutSeq.layout_sequence(seq) do
      nil -> nil
      canvas -> {canvas, []}
    end
  end
end
