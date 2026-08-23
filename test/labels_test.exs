defmodule GrokMermaid.LabelsTest do
  use ExUnit.Case, async: true

  alias GrokMermaid.Labels

  test "clean_label unquotes, strips markup and decodes entities" do
    assert Labels.clean_label("\"Hello world\"") == "Hello world"
    assert Labels.clean_label("A &amp; B") == "A & B"
    assert Labels.clean_label("`**bold** text`") == "bold text"
    assert Labels.clean_label("<b>Hi</b> there") == "Hi there"
    # tags stripped as markup, but entity-encoded tags survive as text
    assert Labels.clean_label("&lt;b&gt; literal") == "<b> literal"
  end

  test "wrap_label wraps to width and truncates with an ellipsis" do
    assert Labels.wrap_label("a very long label that should wrap nicely", 12, 3) ==
             ["a very long", "label that", "should wrap…"]

    assert Labels.wrap_label("supercalifragilistic", 8, 2) == ["supercal", "ifragil…"]

    assert Labels.wrap_label("some_long_identifier_name_here", 10, 2) == [
             "some_long_",
             "identifie…"
           ]
  end

  test "fit_label truncates leaving room for the ellipsis" do
    assert Labels.fit_label("a much too long edge label", 10) == "a much to…"
    assert Labels.fit_label("short", 10) == "short"
  end

  test "decode_html_entities decodes once, not recursively" do
    assert Labels.decode_html_entities("a &amp;lt; b") == "a &lt; b"
    # a stray & stays literal
    assert Labels.decode_html_entities("x & y") == "x & y"
  end

  test "strip_html_tags removes formatting tags only" do
    assert Labels.strip_html_tags("keep <b>gone</b> and <Vec<String>>") ==
             "keep gone and <Vec<String>>"
  end

  test "strip_markdown keeps snake_case underscores" do
    assert Labels.strip_markdown("**bold** and snake_case *ok*") == "bold and snake_case ok"
  end

  test "ascii case folding and control stripping" do
    assert Labels.ascii_upper("flowchartLR") == "FLOWCHARTLR"
    assert Labels.strip_controls("a\u0000b\u001bc") == "abc"
  end

  test "src_lines strips trailing CR and no final empty line" do
    assert Labels.src_lines("a\r\nb\n") == ["a", "b"]
    assert Labels.src_lines("x") == ["x"]
  end
end
