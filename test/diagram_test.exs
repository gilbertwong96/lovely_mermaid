defmodule GrokMermaid.DiagramTest do
  use ExUnit.Case, async: true

  # Golden outputs produced by the TS reference (lovely-mermaid) and
  # checked against its `test/cases/` corpus.

  describe "pie" do
    test "renders a labelled bar list with title" do
      art =
        GrokMermaid.render("""
        pie title Pets
          "Dogs" : 386
          "Cats" : 85
          "Rats" : 15
        """)

      assert art.plain == [
               "             Pets",
               "Dogs  ███████████████▉░░░░  79%",
               "Cats  ███▌░░░░░░░░░░░░░░░░  17%",
               "Rats  ▋░░░░░░░░░░░░░░░░░░░   3%"
             ]
    end

    test "showData appends raw values" do
      art =
        GrokMermaid.render("""
        pie showData
          "A" : 3
          "B" : 1
        """)

      assert art.plain == [
               "A  ███████████████░░░░░  75%  (3)",
               "B  █████░░░░░░░░░░░░░░░  25%  (1)"
             ]
    end

    test "eighth-block rounding carries into a full cell" do
      art = GrokMermaid.render("pie\n  \"a\" : 999\n  \"b\" : 1\n")
      assert Enum.at(art.plain, 0) =~ "a  ████████████████████ 100%"
      assert Enum.at(art.plain, 1) =~ "b  ▏░░░░░░░░░░░░░░░░░░░   0%"
    end

    test "unreadable statements are dropped with warnings" do
      art = GrokMermaid.render("pie\n  \"a\" : 1\n  garbage\n  \"b\" : 2\n")
      assert Enum.count(art.plain) == 2
      assert art.warnings == ["dropped, unreadable statement: \"garbage\""]
    end

    test "nil when no slices parse" do
      assert GrokMermaid.render("pie\n  garbage\n") == nil
      assert GrokMermaid.render("flowchart TD\n  A --> B\n") != nil
    end
  end

  describe "mindmap" do
    test "renders an indentation tree with guides" do
      art =
        GrokMermaid.render("""
        mindmap
          root((App))
            UI
              Buttons
              Theme
            Backend
              DB
        """)

      assert art.plain == [
               "App",
               "├── UI",
               "│   ├── Buttons",
               "│   └── Theme",
               "└── Backend",
               "    └── DB"
             ]
    end

    test "decoration lines are skipped" do
      art = GrokMermaid.render("mindmap\n  root\n    :::icon\n    child\n")
      assert art.plain == ["root", "└── child"]
    end

    test "%% comments and blank lines are skipped" do
      art = GrokMermaid.render("mindmap\n  root %% comment\n    child\n")
      assert art.plain == ["root", "└── child"]
    end

    test "nil when no nodes" do
      assert GrokMermaid.render("mindmap\n  \n") == nil
    end
  end

  describe "timeline" do
    test "renders periods, events and sections" do
      art =
        GrokMermaid.render("""
        timeline
          title History of the web
          section Early days
          1991 : WWW
          2004 : Web 2.0 : Social media
          section Modern
          2023 : LLMs everywhere
        """)

      assert art.plain == [
               "── History of the web ──",
               "Early days",
               "1991 ─ WWW",
               "2004 ─ Web 2.0",
               "     ─ Social media",
               "Modern",
               "2023 ─ LLMs everywhere"
             ]
    end

    test "a bare period renders event-less" do
      art = GrokMermaid.render("timeline\n  2020\n")
      assert art.plain == ["2020"]
    end

    test "unreadable statements are dropped with warnings" do
      art = GrokMermaid.render("timeline\n  2020 : : event\n")
      assert art == nil
    end

    test "nil when no rows" do
      assert GrokMermaid.render("timeline\n") == nil
    end
  end

  describe "gitgraph" do
    test "renders commit lanes with branches and merges" do
      art =
        GrokMermaid.render("""
        gitGraph
          commit id: "c1"
          branch feature
          commit id: "c2"
          checkout main
          commit id: "c3"
          merge feature tag: "v1.0"
          commit id: "c5"
        """)

      assert art.plain == [
               "●   c5 (main)",
               "●   [v1.0] ⇐ feature",
               "├─┐",
               "● │ c3",
               "│ ● c2 (feature)",
               "├─┘",
               "●   c1"
             ]
    end

    test "unnamed commits get auto ids" do
      art = GrokMermaid.render("gitGraph\n  commit\n  commit\n")
      assert Enum.any?(art.plain, &(&1 =~ "c0"))
      assert Enum.any?(art.plain, &(&1 =~ "c1"))
    end

    test "cherry-pick shows a pick marker" do
      art = GrokMermaid.render("gitGraph\n  commit\n  cherry-pick id: \"abc\"\n")
      assert Enum.any?(art.plain, &(&1 =~ "⟲ abc"))
    end

    test "quoted branch names carry spaces and keywords" do
      art = GrokMermaid.render("gitGraph\n  commit\n  branch \"feat x\"\n  commit\n")
      assert Enum.any?(art.plain, &(&1 =~ "c1 (feat x)"))
      refute Enum.any?(art.plain, &(&1 =~ "(\"feat"))
    end

    test "unreadable statements are dropped with warnings" do
      art = GrokMermaid.render("gitGraph\n  commit\n  branch\n  checkout nowhere\n")
      assert Enum.count(art.warnings) == 2
    end

    test "nil when no commits" do
      assert GrokMermaid.render("gitGraph\n") == nil
    end
  end

  describe "diagram_kind" do
    test "reports the new kinds" do
      assert GrokMermaid.diagram_kind("pie title x\n") == :pie
      assert GrokMermaid.diagram_kind("mindmap\n  root\n") == :mindmap
      assert GrokMermaid.diagram_kind("timeline\n  a : b\n") == :timeline
      assert GrokMermaid.diagram_kind("gitGraph LR:\n  commit\n") == :gitgraph
    end
  end
end
