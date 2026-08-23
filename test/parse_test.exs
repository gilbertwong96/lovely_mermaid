defmodule GrokMermaid.ParseTest do
  use ExUnit.Case, async: true

  alias GrokMermaid.{Graph, Parse}

  defp labels(g), do: Enum.map(g.nodes, & &1.label)
  defp shapes(g), do: Enum.map(g.nodes, & &1.shape)

  defp plain_edges(g),
    do: Enum.map(g.edges, &{&1.from, &1.to, &1.label, &1.head_to, &1.head_from, &1.line})

  test "diagram_kind detects the declared type" do
    assert Parse.diagram_kind("flowchart LR\n A --> B") == :flowchart
    assert Parse.diagram_kind("graph TD\n A --> B") == :flowchart
    assert Parse.diagram_kind("sequenceDiagram\n A->>B: hi") == :sequence
    assert Parse.diagram_kind("stateDiagram-v2\n A --> B") == :state
    assert Parse.diagram_kind("classDiagram\n class A") == :class
    assert Parse.diagram_kind("erDiagram\n A ||--o{ B") == :er
    assert Parse.diagram_kind("something else") == nil
  end

  test "parses nodes, shapes and labeled edges" do
    g =
      Parse.parse_graph("""
      graph TD
        A[Start] --> B{Check?}
        B -->|yes| C[Done]
        B -->|no| C
      """)

    assert labels(g) == ["Start", "Check?", "Done"]
    assert shapes(g) == [:rect, :diamond, :rect]
    assert g.dir == :down

    assert plain_edges(g) == [
             {0, 1, nil, :arrow, :none, :solid},
             {1, 2, "yes", :arrow, :none, :solid},
             {1, 2, "no", :arrow, :none, :solid}
           ]

    assert g.warnings == []
  end

  test "parses a chain and the LR direction" do
    g = Parse.parse_graph("flowchart LR\n  A --> B --> C")
    assert g.dir == :right

    assert plain_edges(g) == [
             {0, 1, nil, :arrow, :none, :solid},
             {1, 2, nil, :arrow, :none, :solid}
           ]
  end

  test "quoted labels survive statement splitting" do
    g = Parse.parse_graph("graph TD\n  A[\"a; b\"] --> B")
    assert labels(g) == ["a; b", "B"]
  end

  test "a link without a target warns and keeps the rest" do
    g = Parse.parse_graph("graph TD\n  A -->\n  B --> C")
    assert labels(g) == ["A", "B", "C"]
    assert plain_edges(g) == [{1, 2, nil, :arrow, :none, :solid}]
    assert g.warnings == ["dropped, link has no target: \"A -->\""]
  end

  test "an unclosed label swallows the rest as text and warns" do
    g = Parse.parse_graph("graph TD\n  A[oops --> B")
    assert labels(g) == ["oops --> B"]
    assert g.edges == []
    assert g.warnings == ["node \"A\": label is missing its closing `]`"]
  end

  test "& fans out into a cross product" do
    g = Parse.parse_graph("graph TD\n  A & B --> C")

    assert plain_edges(g) == [
             {0, 2, nil, :arrow, :none, :solid},
             {1, 2, nil, :arrow, :none, :solid}
           ]
  end

  test "subgraphs record groups and parentage" do
    g =
      Parse.parse_graph("""
      graph TD
        subgraph one[Group One]
          A --> B
        end
        C --> A
      """)

    assert labels(g) == ["A", "B", "C"]
    assert g.groups == [%{id: "one", label: "Group One", parent: nil}]

    assert plain_edges(g) == [
             {0, 1, nil, :arrow, :none, :solid},
             {2, 0, nil, :arrow, :none, :solid}
           ]
  end

  test "left-pointing arrows reverse the endpoints" do
    g = Parse.parse_graph("graph TD\n  A <-- B")
    assert plain_edges(g) == [{1, 0, nil, :arrow, :none, :solid}]
  end

  test "trailing o/x heads decorate the target" do
    g = Parse.parse_graph("graph TD\n  A --o B")
    assert plain_edges(g) == [{0, 1, nil, :circle, :none, :solid}]
  end

  test "line kinds parse from the operator" do
    assert Parse.parse_graph("graph TD\n  A ==> B") |> plain_edges() == [
             {0, 1, nil, :arrow, :none, :thick}
           ]

    assert Parse.parse_graph("graph TD\n  A -.-> B") |> plain_edges() == [
             {0, 1, nil, :arrow, :none, :dotted}
           ]
  end

  test "inline labels `-- text -->`" do
    g = Parse.parse_graph("graph TD\n  A -- hello --> B")
    assert plain_edges(g) == [{0, 1, "hello", :arrow, :none, :solid}]
  end

  test "non-diagram sources return nil" do
    assert Parse.parse_graph("something else") == nil
    assert Parse.parse_graph("sequenceDiagram\n A->>B: hi") == nil
  end

  test "split_statements handles quotes and comments" do
    assert Parse.split_statements("A --> B; C --> D") == ["A --> B", "C --> D"]
    assert Parse.split_statements("A[\"x;y\"] --> B") == ["A[\"x;y\"] --> B"]
    assert Parse.split_statements("A --> B %% comment") == ["A --> B"]
  end
end
