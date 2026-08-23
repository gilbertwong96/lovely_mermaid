defmodule GrokMermaid.LayoutTest do
  use ExUnit.Case, async: true

  alias GrokMermaid.{Canvas, Layout, Parse}

  defp render_plain(src) do
    graph = Parse.parse_graph(src)
    canvas = Layout.layout_flowchart(graph)
    canvas |> Canvas.to_lines() |> elem(0)
  end

  test "LR chain with horizontal arrows" do
    assert render_plain("flowchart LR\n  A[Start] --> B[Done]") == [
             "┌───────┐    ┌──────┐",
             "│ Start ├───▶│ Done │",
             "└───────┘    └──────┘"
           ]
  end

  test "TD chain with vertical arrows" do
    assert render_plain("graph TD\n  A --> B\n  B --> C") == [
             " ┌───┐",
             " │ A │",
             " └─┬─┘",
             "   │",
             "   ▼",
             " ┌───┐",
             " │ B │",
             " └─┬─┘",
             "   │",
             "   ▼",
             " ┌───┐",
             " │ C │",
             " └───┘"
           ]
  end

  test "TD branch with diamond and labeled edges" do
    assert render_plain(
             "graph TD\n  A[Parse source] --> B{Supported?}\n  B -->|yes| C[Lay out]\n  B -->|no| D[Framed source]"
           ) == [
             "      ┌──────────────┐",
             "      │ Parse source │",
             "      └───────┬──────┘",
             "              │",
             "              ▼",
             "       ╭────────────╮",
             "       │ Supported? │",
             "       ╰──────┬─────╯",
             "      ┌───────┴────────┐",
             "      ▼yes             ▼no",
             " ┌─────────┐   ┌───────────────┐",
             " │ Lay out │   │ Framed source │",
             " └─────────┘   └───────────────┘"
           ]
  end

  test "TD merge into a single target" do
    assert render_plain("graph TD\n  A --> B\n  A --> C\n  B --> D\n  C --> D") == [
             "     ┌───┐",
             "     │ A │",
             "     └─┬─┘",
             "   ┌───┴───┐",
             "   ▼       ▼",
             " ┌───┐   ┌───┐",
             " │ B │   │ C │",
             " └─┬─┘   └─┬─┘",
             "   └───┬───┘",
             "       ▼",
             "     ┌───┐",
             "     │ D │",
             "     └───┘"
           ]
  end

  test "skip edges route through a lane" do
    assert render_plain("graph TD\n  A --> B\n  B --> C\n  C --> D\n  A --> D") == [
             " ┌───┐",
             " │ A ├─┐",
             " └─┬─┘ │",
             "   │   │",
             "   ▼   │",
             " ┌───┐ │",
             " │ B │ │",
             " └─┬─┘ │",
             "   │   │",
             "   ▼   │",
             " ┌───┐ │",
             " │ C │ │",
             " └─┬─┘ │",
             "   │   │",
             "   ▼   │",
             " ┌───┐ │",
             " │ D │◄┘",
             " └───┘"
           ]
  end

  test "line styles render per edge" do
    assert render_plain("graph TD\n  A ==> B\n  B -.-> C") == [
             " ┌───┐",
             " │ A │",
             " └─┬─┘",
             "   ┃",
             "   ▼",
             " ┌───┐",
             " │ B │",
             " └─┬─┘",
             "   ╎",
             "   ▼",
             " ┌───┐",
             " │ C │",
             " └───┘"
           ]
  end
end
