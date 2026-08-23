defmodule LovelyMermaid.ClassDefTest do
  use ExUnit.Case, async: true

  alias LovelyMermaid.ClassStyle

  # Ported assertions from lovely-mermaid's render.test.ts / spans.test.ts:
  # author classes, classDefs, hrefs and frontmatter titles.

  test "author classes reach the spans and classDefs the art" do
    art =
      LovelyMermaid.render("""
      flowchart TD
        A[Hot node]:::hot --> B
        class B cold
        classDef hot fill:#f96,stroke:#333
        classDef cold fill:#69f
      """)

    assert art.class_defs == %{
             "hot" => %{"fill" => "#f96", "stroke" => "#333"},
             "cold" => %{"fill" => "#69f"}
           }

    classed = art.styled |> List.flatten() |> Enum.filter(&(&1.classes != nil))

    assert Enum.any?(classed, fn s -> s.text =~ "Hot node" and s.classes == ["hot"] end)
    assert Enum.any?(classed, fn s -> s.text =~ "B" and s.classes == ["cold"] end)
    # Cells the node did not paint carry no classes.
    refute Enum.any?(art.styled |> List.flatten(), fn s ->
             s.role == :edge and s.classes != nil
           end)
  end

  test "state classDefs and class assignments are surfaced" do
    art =
      LovelyMermaid.render(
        "stateDiagram-v2\n A --> B\n class A warning\n classDef warning fill:#f00"
      )

    assert art.class_defs == %{"warning" => %{"fill" => "#f00"}}

    assert Enum.any?(art.styled |> List.flatten(), fn s ->
             s.text =~ "A" and Map.get(s, :classes) == ["warning"]
           end)
  end

  test "::: classes are captured in state and class diagrams" do
    st =
      LovelyMermaid.render(
        "stateDiagram-v2\n [*] --> Still:::quiet\n Still --> Moving\n classDef quiet fill:#eee"
      )

    assert st.class_defs == %{"quiet" => %{"fill" => "#eee"}}

    assert Enum.any?(st.styled |> List.flatten(), fn s ->
             s.text =~ "Still" and Map.get(s, :classes) == ["quiet"]
           end)

    cls =
      LovelyMermaid.render(
        "classDiagram\n class Agent:::smart\n Agent <|-- Duck\n classDef smart fill:#69f"
      )

    assert cls.class_defs == %{"smart" => %{"fill" => "#69f"}}

    assert Enum.any?(cls.styled |> List.flatten(), fn s ->
             s.text =~ "Agent" and Map.get(s, :classes) == ["smart"]
           end)
  end

  test "the source box carries no classDefs" do
    art = LovelyMermaid.SourceBox.source_box("gantt\n title Plan", 80)
    assert art.class_defs == %{}
  end

  test "a frontmatter title carries the title role" do
    art = LovelyMermaid.render("---\ntitle: Order flow\n---\nflowchart TD\n A --> B")
    assert hd(art.plain) == "Order flow"
    assert List.first(art.styled) == [%LovelyMermaid.Span{text: "Order flow", role: :title}]
  end

  test "click and link statements land on the spans as href" do
    fc =
      LovelyMermaid.render(
        "flowchart TD\n A[Docs] --> B\n click A \"https://example.com/docs\" \"open\""
      )

    assert Enum.any?(fc.styled |> List.flatten(), fn s ->
             s.text =~ "Docs" and Map.get(s, :href) == "https://example.com/docs"
           end)

    # The whole box is the link, blank interior included; B carries none.
    assert Enum.any?(fc.styled |> List.flatten(), fn s ->
             s.role == :border and Map.get(s, :href) == "https://example.com/docs"
           end)

    refute Enum.any?(fc.styled |> List.flatten(), fn s ->
             s.text =~ "B" and s.href != nil
           end)

    cls =
      LovelyMermaid.render(
        "classDiagram\n class Agent {\n +run()\n }\n link Agent \"https://example.com\""
      )

    assert Enum.any?(cls.styled |> List.flatten(), fn s ->
             s.text =~ "Agent" and Map.get(s, :href) == "https://example.com"
           end)

    # Callback forms carry nothing a terminal can open.
    cb = LovelyMermaid.render("flowchart TD\n A --> B\n click A call doIt() \"tip\"")
    refute Enum.any?(cb.styled |> List.flatten(), fn s -> s.href != nil end)
  end

  test "toAnsi wraps linked spans in OSC 8, stripping back to plain" do
    art = LovelyMermaid.render("flowchart TD\n A[Docs] --> B\n click A \"https://example.com\"")
    out = LovelyMermaid.Ansi.to_ansi(art) |> Enum.join("\n")
    assert out =~ "\e]8;;https://example.com\e\\"

    stripped =
      out
      |> String.replace("\e]8;;https://example.com\e\\", "")
      |> String.replace("\e]8;;\e\\", "")
      |> String.replace(~r/\e\[[0-9;]*m/, "")

    assert stripped == Enum.join(art.plain, "\n")
  end

  test "toAnsi applies class styles over the role theme" do
    art =
      LovelyMermaid.render(
        "flowchart TD\n A[Hot]:::red --> B\n classDef red fill:#ff9966,color:#000000"
      )

    out = LovelyMermaid.Ansi.to_ansi(art, %{border: "2"}) |> Enum.join("\n")
    assert out =~ "48;2;255;153;102"
    assert out =~ "\e[2m"
  end

  test "a fill with no color gets a contrasting foreground" do
    art = LovelyMermaid.render("flowchart TD\n A[Pale]:::pale --> B\n classDef pale fill:#ffffe0")
    out = LovelyMermaid.Ansi.to_ansi(art) |> Enum.join("\n")
    assert out =~ "38;2;0;0;0"
  end

  test "a bold-only class bolds the themed look instead of replacing it" do
    art = LovelyMermaid.render("flowchart TD\n A[Em]:::em --> B\n classDef em font-weight:bold")
    out = LovelyMermaid.Ansi.to_ansi(art, %{border: "2;36"}) |> Enum.join("\n")
    assert out =~ "\e[1;2;36m"
    assert out =~ "\e[2;36m"
  end

  test "resolveClassStyle normalizes colors and merges classes in order" do
    defs = %{
      "hot" => %{"fill" => "#f96", "stroke" => "rgb(51, 51, 51)", "font-weight" => "bold"},
      "cold" => %{"fill" => "lightblue", "stroke-width" => "4px", "wobble" => "yes"}
    }

    assert ClassStyle.resolve_class_style(["hot"], defs) == %{
             fill: "#ff9966",
             stroke: "#333333",
             bold: true
           }

    assert ClassStyle.resolve_class_style(["hot", "cold", "ghost"], defs) == %{
             fill: "#add8e6",
             stroke: "#333333",
             bold: true
           }

    assert ClassStyle.resolve_class_style(["ghost"], defs) == nil
    assert ClassStyle.resolve_class_style(nil, defs) == nil

    assert ClassStyle.resolve_class_style(["thin"], %{"thin" => %{"stroke-width" => "1px"}}) ==
             nil
  end

  test "contrastOn picks the readable foreground" do
    assert ClassStyle.contrast_on("#ffffe0") == "#000000"
    assert ClassStyle.contrast_on("#4b0082") == "#ffffff"
  end
end
