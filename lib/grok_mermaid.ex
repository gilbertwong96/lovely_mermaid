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

  alias GrokMermaid.{
    Art,
    Canvas,
    Span,
    GitGraph,
    Labels,
    Layout,
    LayoutSeq,
    Mindmap,
    Parse,
    Pie,
    Timeline,
    Width
  }

  @doc """
  Renders a Mermaid source to Unicode art.

  Returns `%GrokMermaid.Art{}` or `nil` when there is nothing to draw.
  """
  @spec render(String.t()) :: Art.t() | nil
  def render(src) when is_binary(src) do
    src = Labels.strip_controls(src)

    if String.trim(src) == "" do
      nil
    else
      case attempt(src) do
        nil -> nil
        {canvas, class_defs, warnings} -> canvas_to_art(canvas, class_defs, warnings, src)
      end
    end
  end

  def render(_), do: nil

  @doc "What kind of diagram the source declares, or `nil`."
  @spec diagram_kind(String.t()) :: atom() | nil
  def diagram_kind(src), do: Parse.diagram_kind(src)

  defp canvas_to_art(canvas, class_defs, warnings, src) do
    {plain, styled, width} = Canvas.to_lines(canvas)

    art = %Art{
      plain: plain,
      styled: styled,
      width: width,
      class_defs: class_defs,
      warnings: warnings
    }

    # A frontmatter `title:` is centred above the art, in the `title` role.
    case Parse.frontmatter_title(src) do
      nil ->
        art

      title ->
        tw = Width.string_width(title)
        width = max(art.width, tw)
        pad = String.duplicate(" ", div(width - tw, 2))

        %{
          art
          | width: width,
            plain: [pad <> title, "" | art.plain],
            styled: [
              if(pad == "",
                do: [%Span{text: title, role: :title}],
                else: [%Span{text: pad, role: :none}, %Span{text: title, role: :title}]
              ),
              []
              | art.styled
            ]
        }
    end
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

              {canvas, class_defs, warnings} ->
                dropped = lines |> List.last() |> String.trim()

                {canvas, class_defs,
                 warnings ++ ["dropped, unreadable final line: \"#{dropped}\""]}
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
          graph -> draw_graph(graph)
        end

      :state ->
        case Parse.parse_state(src) do
          nil -> nil
          graph -> draw_graph(graph)
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

      :pie ->
        Pie.render(src)

      :mindmap ->
        Mindmap.render(src)

      :timeline ->
        Timeline.render(src)

      :gitgraph ->
        GitGraph.render(src)

      nil ->
        nil
    end
  end

  defp draw_graph(graph, _kind \\ :flowchart) do
    canvas =
      if graph.groups == [] do
        Layout.layout_flowchart(graph)
      else
        Layout.layout_grouped(graph)
      end

    if canvas, do: {canvas, graph.class_defs, graph.warnings}, else: nil
  end

  defp draw_class(graph, infos) do
    canvas = Layout.layout_class(graph, infos)
    if canvas, do: {canvas, graph.class_defs, []}, else: nil
  end

  defp draw_sequence(seq) do
    case LayoutSeq.layout_sequence(seq) do
      nil -> nil
      canvas -> {canvas, %{}, []}
    end
  end
end
