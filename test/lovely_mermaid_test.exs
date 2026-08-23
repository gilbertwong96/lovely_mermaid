defmodule LovelyMermaidTest do
  use ExUnit.Case, async: true

  alias LovelyMermaid

  defp render_plain(src) do
    art = LovelyMermaid.render(src)
    if art, do: art.plain, else: nil
  end

  test "state diagrams render with start/end pseudo-nodes" do
    assert render_plain("""
           stateDiagram-v2
             [*] --> Idle
             Idle --> Active: start
             Active --> Idle: stop
             Active --> [*]
           """) == [
             "   ╭───╮",
             "   │ ● │",
             "   ╰─┬─╯",
             "     │",
             "     ▼",
             " ╭──────╮  stop",
             " │ Idle │◄──────┐",
             " ╰───┬──╯       │",
             "     │          │",
             "     ▼start     │",
             "╭────────╮      │",
             "│ Active ├──────┘",
             "╰────┬───╯",
             "     │",
             "     ▼",
             "   ╭───╮",
             "   │ ● │",
             "   ╰───╯"
           ]
  end

  test "class diagrams render compartment boxes and relations" do
    assert render_plain("""
           classDiagram
             class Animal
             Animal : +String name
             Animal : +int age
             Animal : +makeSound()
             Animal <|-- Dog
             Dog : +bark()
           """) == [
             "┌──────────────┐",
             "│    Animal    │",
             "├──────────────┤",
             "│ +String name │",
             "│ +int age     │",
             "├──────────────┤",
             "│ +makeSound() │",
             "└───────△──────┘",
             "        │",
             "        │",
             "   ┌─────────┐",
             "   │   Dog   │",
             "   ├─────────┤",
             "   │ +bark() │",
             "   └─────────┘"
           ]
  end

  test "ER diagrams render cardinalities on edges" do
    assert render_plain("""
           erDiagram
             CUSTOMER ||--o{ ORDER : places
             ORDER ||--|{ LINE-ITEM : contains
           """) == [
             " ┌──────────┐",
             " │ CUSTOMER │",
             " └─────┬────┘",
             "       │",
             "       │1 places 0..*",
             "   ┌───────┐",
             "   │ ORDER │",
             "   └───┬───┘",
             "       │",
             "       │1 contains 1..*",
             " ┌───────────┐",
             " │ LINE-ITEM │",
             " └───────────┘"
           ]
  end

  test "sequence diagrams render lifelines, messages and dividers" do
    art =
      LovelyMermaid.render("""
      sequenceDiagram
        participant Alice
        participant Bob
        Alice->>John: Hello John, how are you?
        loop Healthcheck
          John->>John: Fight against hypochondria
        end
        Note right of John: Rational thoughts prevail!
        John-->>Alice: Great!
        John->>Bob: How about you?
      """)

    joined = Enum.join(art.plain, "\n")
    assert joined =~ "│ Alice │"
    assert joined =~ "Hello John, how are you?"
    assert joined =~ "── loop Healthcheck"
    assert joined =~ "Fight against hypochondria"
    assert joined =~ "Rational thoughts prevail!"
    assert joined =~ "Great!"
    assert joined =~ "◄╌╌╌"
  end

  test "flowchart v2 @{shape: ...} nodes render with the mapped silhouette" do
    assert render_plain("flowchart LR\n  A@{shape: cyl, label: \"DB\"} --> B") == [
             "╭────╮    ┌───┐",
             "│ DB ├───▶│ B │",
             "╰────╯    └───┘"
           ]
  end

  test "diamond nodes render as double-line boxes" do
    assert render_plain("flowchart LR\n  A{Check} --> B") == [
             "╔═══════╗    ┌───┐",
             "║ Check ╟───▶│ B │",
             "╚═══════╝    └───┘"
           ]

    assert render_plain("flowchart LR\n  A@{shape: diam} --> B") == [
             "╔═══╗    ┌───┐",
             "║ A ╟───▶│ B │",
             "╚═══╝    └───┘"
           ]
  end

  test "LR branching routes through the bus" do
    assert render_plain("flowchart LR\n  A --> B\n  A --> C\n  B --> D\n  C --> D") == [
             "         ┌───┐",
             "     ┌──▶│ B ├┐",
             "┌───┐│   └───┘│   ┌───┐",
             "│ A ├┤        ├──▶│ D │",
             "└───┘│   ┌───┐│   └───┘",
             "     └──▶│ C ├┘",
             "         └───┘"
           ]
  end

  test "render returns nil for unsupported sources" do
    assert LovelyMermaid.render("") == nil
    assert LovelyMermaid.render("just some text") == nil
  end

  test "diagram_kind is exported" do
    assert LovelyMermaid.diagram_kind("flowchart LR\n A --> B") == :flowchart
    assert LovelyMermaid.diagram_kind("sequenceDiagram\n A->>B: hi") == :sequence
    assert LovelyMermaid.diagram_kind("nope") == nil
  end

  test "source_box frames the source" do
    art = LovelyMermaid.SourceBox.source_box("flowchart LR\n  A --> B", 20)
    assert art.plain |> hd() =~ "╭ mermaid: flowchart"
    assert art.width > 10

    assert Enum.all?(art.styled, fn row ->
             Enum.all?(row, fn span -> span.role in [:border, :title, :text] end)
           end)
  end

  test "to_ansi colors styled spans" do
    art = LovelyMermaid.SourceBox.source_box("graph TD\n  A --> B", 20)
    lines = LovelyMermaid.Ansi.to_ansi(art)
    assert Enum.all?(lines, &String.contains?(&1, "\e["))
  end
end
