defmodule GrokMermaid.CoverageTest do
  # Negative paths, edge inputs and layout variants that the golden
  # end-to-end tests do not exercise. Covering these raises the floor of
  # what render/1 promises: nil on refusal, warnings on salvage.
  use ExUnit.Case, async: true

  alias GrokMermaid
  alias GrokMermaid.{Canvas, Labels, SourceBox, Width}

  # ---------------------------------------------------------------- entry

  test "render rejects non-string input" do
    assert GrokMermaid.render(123) == nil
    assert GrokMermaid.render(nil) == nil
  end

  test "bare headers render nothing" do
    for header <- [
          "flowchart",
          "stateDiagram-v2",
          "classDiagram",
          "erDiagram",
          "sequenceDiagram"
        ] do
      assert GrokMermaid.render(header) == nil, header
      assert GrokMermaid.diagram_kind(header) != nil, header
    end
  end

  test "strict grammars retry without the final line" do
    art =
      GrokMermaid.render("stateDiagram-v2\n  [*] --> Idle\n  Idle --> Active: start\n  bad line")

    assert art != nil
    assert Enum.any?(art.warnings, &String.contains?(&1, "dropped, unreadable final line"))
    assert Enum.join(art.plain, "\n") =~ "Idle"
  end

  test "retry fails too when the salvage is unreadable" do
    assert GrokMermaid.render("stateDiagram-v2\n  garbage one\n  garbage two") == nil
  end

  test "flowchart salvage keeps warnings from the kept prefix" do
    art = GrokMermaid.render("flowchart TD\n  A -->\n  garbage")
    # flowchart is lenient: the stray line is dropped with a warning, art stays
    assert art != nil
    assert Enum.any?(art.warnings, &String.contains?(&1, "dropped"))
  end

  # ------------------------------------------------------------------ graph

  test "state direction RL and BT orient the layout" do
    rl = GrokMermaid.render("stateDiagram-v2\n  direction RL\n  [*] --> A\n  A --> [*]")
    assert rl != nil

    bt = GrokMermaid.render("stateDiagram-v2\n  direction BT\n  [*] --> A\n  A --> [*]")
    assert bt != nil
  end

  test "state descriptions retitle existing states and create new ones" do
    art =
      GrokMermaid.render("""
      stateDiagram-v2
        [*] --> Idle
        Idle : the resting state
        BrandNew : created by description
        Idle --> [*]
      """)

    joined = Enum.join(art.plain, "\n")
    assert joined =~ "the resting state"
    assert joined =~ "created by description"
  end

  test "re-declaring a node with a label updates it" do
    art = GrokMermaid.render("flowchart TD\n  A[first] --> B\n  A[renamed] --> C")
    assert Enum.join(art.plain, "\n") =~ "renamed"
  end

  # ------------------------------------------------------------------ parse

  test "state grammar rejects unreadable statements" do
    assert GrokMermaid.render("stateDiagram-v2\n  %% only a comment") == nil
  end

  test "class grammar rejects unreadable statements" do
    assert GrokMermaid.render("classDiagram\n  ???") == nil
    assert GrokMermaid.render("classDiagram\n  bad line") == nil
  end

  test "er grammar rejects unreadable statements" do
    assert GrokMermaid.render("erDiagram\n  B --") == nil
  end

  test "sequence grammar rejects unreadable statements" do
    assert GrokMermaid.render("sequenceDiagram\n  ??? one\n  ??? two") == nil
  end

  test "sequence participant without a name rejects" do
    assert GrokMermaid.render("sequenceDiagram\n  participant") == nil
  end

  test "over-capacity graphs are refused" do
    src = "flowchart TD\n" <> Enum.map_join(1..130, "\n", &"n#{&1} --> n#{&1 + 1}")
    assert GrokMermaid.render(src) == nil
  end

  # --------------------------------------------------------------- source box

  test "source_box frames empty input" do
    art = SourceBox.source_box("")
    assert art.plain == ["╭ mermaid: diagram ──╮", "╰--------------------╯"]
    assert art.width == 22
  end

  test "source_box without a width does not wrap" do
    art = SourceBox.source_box("flowchart LR\n  A --> B")
    assert Enum.any?(art.plain, &(&1 =~ "flowchart LR"))
  end

  test "source_box hard-wraps long tokens" do
    art = SourceBox.source_box("flowchart\n  #{String.duplicate("x", 50)}", 20)
    assert Enum.count(art.plain) == 7
  end

  test "source_box skips leading blank lines" do
    art = SourceBox.source_box("\n\nflowchart TD\n  A --> B", 20)
    refute Enum.any?(art.plain, &(&1 =~ "╭ mermaid:  ╮"))
    assert Enum.any?(art.plain, &(&1 =~ "flowchart TD"))
  end

  # ---------------------------------------------------------------- labels

  test "numeric entities decode, invalid ones are left alone" do
    assert Labels.decode_html_entities("&#65;&#x42;") == "AB"
    assert Labels.decode_html_entities("&#x1F600;") == "😀"
    assert Labels.decode_html_entities("&#0;&#xD800;&#x110000;") == "&#0;&#xD800;&#x110000;"
  end

  test "markdown and html are stripped from labels" do
    assert Labels.clean_label("`**bold** code`") == "bold code"
    assert Labels.clean_label("<b>tag</b>") == "tag"
  end

  test "fit_label elides long words" do
    assert Labels.fit_label(String.duplicate("w", 40), 10) != String.duplicate("w", 40)
    assert String.length(Labels.fit_label(String.duplicate("w", 40), 10)) <= 10
  end

  # ----------------------------------------------------------------- canvas

  test "canvas flips glyphs both ways" do
    assert Canvas.flip_glyph_v("┌") == "└"
    assert Canvas.flip_glyph_v("┐") == "┘"
    assert Canvas.flip_glyph_v("└") == "┌"
    assert Canvas.flip_glyph_v("┘") == "┐"
    assert Canvas.flip_glyph_h("┌") == "┐"
    assert Canvas.flip_glyph_h("┐") == "┌"
    assert Canvas.flip_glyph_h("└") == "┘"
    assert Canvas.flip_glyph_h("┘") == "└"
  end

  test "canvas mask_char decodes junction masks" do
    assert Canvas.mask_char(1) == "│"
    assert Canvas.mask_char(8) == "─"
    assert Canvas.mask_char(15) == "┼"
  end

  test "canvas blit offsets and clips" do
    big = Canvas.new(10, 10)
    sub = Canvas.new(3, 3) |> Canvas.set(1, 1, "X", :text)
    blitted = Canvas.blit(big, sub, 4, 4)
    {lines, _, _} = Canvas.to_lines(blitted)
    assert Enum.any?(lines, &(&1 =~ "X"))
  end

  # ---------------------------------------------------------------- layout

  test "flowchart self loop" do
    art = GrokMermaid.render("flowchart TD\n  A --> B\n  B --> B")
    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "B"
  end

  test "dotted and thick edges render distinct glyphs" do
    art = GrokMermaid.render("flowchart LR\n  A -.-> B\n  C ==> D")
    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "╌"
  end

  test "circle and cross heads render" do
    art = GrokMermaid.render("flowchart LR\n  A o--o B\n  C x--x D")
    assert art != nil
  end

  test "subgraph nesting" do
    art =
      GrokMermaid.render("""
      flowchart TD
        subgraph one
          A --> B
          subgraph two
            B --> C
          end
        end
        C --> D
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "one"
    assert Enum.join(art.plain, "\n") =~ "two"
  end

  # --------------------------------------------------------------- sequence

  test "note over a single participant and edge notes" do
    art =
      GrokMermaid.render("""
      sequenceDiagram
        participant A
        participant B
        Note over A: solo
        Note left of A: lefty
        Note right of B: righty
      """)

    joined = Enum.join(art.plain, "\n")
    assert joined =~ "solo"
    assert joined =~ "lefty"
    assert joined =~ "righty"
  end

  test "sequence autonumber prefixes messages" do
    art =
      GrokMermaid.render("""
      sequenceDiagram
        autonumber
        A->>B: first
        B-->>A: second
      """)

    joined = Enum.join(art.plain, "\n")
    assert joined =~ "1."
    assert joined =~ "2."
  end
end

defmodule GrokMermaid.GrammarTableTest do
  # Syntax-variant tables: each diagram kind's alternative forms, one
  # assertion per variant so a regression names the exact form.
  use ExUnit.Case, async: true

  alias GrokMermaid

  # ------------------------------------------------------------------ state

  test "state declaration forms" do
    quoted = """
    stateDiagram-v2
      [*] --> A
      state "The Machine" as A
    """

    assert GrokMermaid.render(quoted) != nil

    choice = """
    stateDiagram-v2
      [*] --> A
      state A <<choice>>
      A --> B
    """

    assert GrokMermaid.render(choice) != nil

    braced = """
    stateDiagram-v2
      [*] --> A
      state A {
      }
    """

    assert GrokMermaid.render(braced) != nil
  end

  test "state note blocks and transition chains" do
    art =
      GrokMermaid.render("""
      stateDiagram-v2
        [*] --> A
        note right of A
          some text
        end note
        A --> B --> C
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "C"
  end

  test "state hide and scale directives are ignored" do
    art =
      GrokMermaid.render("""
      stateDiagram-v2
        [*] --> A
        hide empty description
        scale 0.8
      """)

    assert art != nil
  end

  # ------------------------------------------------------------------ class

  test "class relation operators all render" do
    for {op, marker} <- [
          {"<|--", "△"},
          {"--|>", "▽"},
          {"<|..", "△"},
          {"..|>", "▽"},
          {"*--", "◆"},
          {"--*", "◆"},
          {"o--", "◇"},
          {"--o", "◇"},
          {"<--", "▲"},
          {"-->", nil},
          {"<..", "▲"},
          {"..>", nil},
          {"--", nil},
          {"..", nil}
        ] do
      src = "classDiagram\n  A #{op} B"
      art = GrokMermaid.render(src)
      assert art != nil, "class op #{op}"
      if marker, do: assert(Enum.join(art.plain, "\n") =~ marker, "marker #{marker} for #{op}")
    end
  end

  test "class member annotation and elision" do
    src = "classDiagram\n  class A\n  A : <<interface>>\n  A : +m1()\n  A : +m2()\n"
    assert GrokMermaid.render(src) != nil

    many =
      "classDiagram\n  class A\n" <>
        Enum.map_join(1..12, "\n", fn i -> "  A : +f#{i}()" end)

    art = GrokMermaid.render(many)
    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "…"
  end

  # -------------------------------------------------------------------- er

  test "er cardinality operators all render" do
    for {op, card_l, card_r} <- [
          {"||--o{", "1", "0..*"},
          {"}o--||", "0..*", "1"},
          {"}o--o{", "0..*", "0..*"},
          {"|o--||", "0..1", "1"},
          {"}o--|{", "0..*", "1..*"}
        ] do
      art = GrokMermaid.render("erDiagram\n  A #{op} B : has")
      assert art != nil, "er op #{op}"
      assert Enum.join(art.plain, "\n") =~ card_l, "left card for #{op}"
      assert Enum.join(art.plain, "\n") =~ card_r, "right card for #{op}"
    end
  end

  test "er attributes and quoted keys" do
    art =
      GrokMermaid.render("""
      erDiagram
        CUSTOMER {
          string name
          int age
        }
        CUSTOMER ||--o{ ORDER : places
        "LINE-ITEM" ||--o{ ORDER : contains
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "name"
    assert Enum.join(art.plain, "\n") =~ "age"
  end

  # -------------------------------------------------------------- sequence

  test "sequence note block forms and participant alias" do
    art =
      GrokMermaid.render("""
      sequenceDiagram
        participant U as User
        Note over U: hello
        U->>U: self
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "User"
  end

  test "sequence rect boxes and activation lines are ignored" do
    art =
      GrokMermaid.render("""
      sequenceDiagram
        A->>B: hi
        rect rgb(0,0,0)
          activate B
          B->>B: work
          deactivate B
        end
        B-->>A: ok
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "ok"
  end

  test "sequence alt/else/end dividers" do
    art =
      GrokMermaid.render("""
      sequenceDiagram
        A->>B: ask
        alt yes
          B->>A: yep
        else no
          B->>A: nope
        end
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "alt yes"
    assert Enum.join(art.plain, "\n") =~ "else no"
  end

  # --------------------------------------------------------------- flowchart

  test "flowchart subgraph over-cap refuses" do
    src =
      "flowchart TD\n" <>
        Enum.map_join(1..7, fn d ->
          String.duplicate("  ", d - 1) <> "subgraph g#{d}\n"
        end) <>
        "  A --> B\n" <>
        Enum.map_join(1..7, fn d -> String.duplicate("  ", 7 - d) <> "end\n" end)

    assert GrokMermaid.render(src) == nil
  end

  test "flowchart label with a missing closer warns" do
    art = GrokMermaid.render("flowchart TD\n  A[unclosed")
    assert art != nil
    assert Enum.any?(art.warnings, &String.contains?(&1, "closing"))
  end
end

defmodule GrokMermaid.LayoutVariantTest do
  # Layout branches the golden suites do not reach: barycenter sweeps on
  # crossing graphs, back-edge routing, self-loop labels, proxy nodes and
  # the lenient flowchart warning paths.
  use ExUnit.Case, async: true

  alias GrokMermaid

  # ------------------------------------------------------------------ layout

  test "crossing graphs drive the barycenter sweep" do
    art =
      GrokMermaid.render("""
      flowchart TD
        A --> C
        A --> D
        B --> C
        B --> D
      """)

    assert art != nil
    joined = Enum.join(art.plain, "\n")
    assert joined =~ "C"
    assert joined =~ "D"
  end

  test "LR back edges route through a lane" do
    art =
      GrokMermaid.render("""
      flowchart LR
        A --> B
        B --> A
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "B"
  end

  test "long LR chains with a back edge" do
    art =
      GrokMermaid.render("""
      flowchart LR
        A --> B --> C
        C --> A
      """)

    assert art != nil
  end

  test "self loops with labels reserve width in both directions" do
    td = GrokMermaid.render("flowchart TD\n  A --> B\n  B -- loops --> B")
    assert td != nil
    assert Enum.join(td.plain, "\n") =~ "loops"

    lr = GrokMermaid.render("flowchart LR\n  A --> B\n  B -- loops --> B")
    assert lr != nil
    assert Enum.join(lr.plain, "\n") =~ "loops"
  end

  test "a node sharing a subgraph id acts as its proxy" do
    art =
      GrokMermaid.render("""
      flowchart TD
        subgraph one
          A --> B
        end
        one --> C
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "one"
  end

  # ---------------------------------------------------------- lenient paths

  test "bare end statement closes the current group" do
    art =
      GrokMermaid.render("""
      flowchart TD
        end
        A --> B
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "B"
  end

  test "a stray token after a node warns about a missing link" do
    art = GrokMermaid.render("flowchart TD\n  A ~~~")
    assert art != nil
    assert Enum.any?(art.warnings, &String.contains?(&1, "dropped, expected a link"))
  end

  # ------------------------------------------------------------------ state

  test "unclosed quoted state declaration refuses" do
    assert GrokMermaid.render("stateDiagram-v2\n  state \"unclosed") == nil
  end

  test "state id with a space refuses" do
    assert GrokMermaid.render("stateDiagram-v2\n  state has space") == nil
  end

  # ---------------------------------------------------------------- class/er

  test "class braces outside a declaration are ignored" do
    art = GrokMermaid.render("classDiagram\n  class A\n  }")
    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "A"
  end

  test "er entity with a bracketed title" do
    art =
      GrokMermaid.render("""
      erDiagram
        CUSTOMER[Customer] {
          string name
        }
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "Customer"
  end

  # -------------------------------------------------------------- sequence

  test "note over two participants spans both" do
    art =
      GrokMermaid.render("""
      sequenceDiagram
        participant A
        participant B
        participant C
        Note over A, C: spanning
      """)

    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "spanning"
  end

  test "note referencing an unknown participant registers it" do
    art = GrokMermaid.render("sequenceDiagram\n  A->>B: hi\n  Note over Missing: x")
    assert art != nil
    assert Enum.join(art.plain, "\n") =~ "Missing"
  end
end
