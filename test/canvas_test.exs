defmodule GrokMermaid.CanvasTest do
  use ExUnit.Case, async: true

  alias GrokMermaid.Canvas

  defp lines(c), do: c |> Canvas.finalize_mask() |> Canvas.to_lines() |> elem(0)

  test "a vertical and horizontal line cross as ┼" do
    c = Canvas.new(7, 5)
    c = Canvas.seg_v(c, 3, 0, 4)
    c = Canvas.seg_h(c, 2, 0, 6)

    assert lines(c) == [
             "   │",
             "   │",
             "───┼───",
             "   │",
             "   │"
           ]
  end

  test "junction adds bits to an occupied cell" do
    c = Canvas.new(9, 5)
    c = Canvas.set(c, 2, 2, "X", :text)
    c = Canvas.seg_v(c, 4, 0, 4)
    c = Canvas.junction(c, 4, 2, 1)

    assert lines(c) == [
             "    │",
             "    │",
             "  X │",
             "    │",
             "    │"
           ]
  end

  test "an edge meeting a box border keeps the border styling" do
    c = Canvas.new(11, 7)

    c =
      Enum.reduce(2..8, c, fn x, c ->
        c = Canvas.set(c, x, 1, "─", :border)
        Canvas.set(c, x, 3, "─", :border)
      end)

    c =
      Enum.reduce(1..3, c, fn y, c ->
        c = Canvas.set(c, 2, y, "│", :border)
        Canvas.set(c, 8, y, "│", :border)
      end)

    c = Canvas.set(c, 5, 2, "T", :text)
    c = Canvas.seg_v(c, 5, 4, 6)
    c = Canvas.junction(c, 5, 3, 2)

    assert lines(c) == [
             "  │─────│",
             "  │  T  │",
             "  │─────│",
             "     │",
             "     │",
             "     │"
           ]
  end

  test "draw_text paints wide glyphs as one character over two cells" do
    c = Canvas.new(6, 2)
    c = Canvas.draw_text(c, "中a", 1, 0, :text)
    {plain, styled, width} = Canvas.to_lines(Canvas.finalize_mask(c))

    assert plain == [" 中a"]
    assert width == 4
    assert styled == [[%{text: " ", role: :none}, %{text: "中a", role: :text}]]
  end

  test "flip_vertical mirrors rows and flips glyphs, text stays readable" do
    c = Canvas.new(5, 3)
    c = Canvas.draw_text(c, "AB", 1, 0, :text)
    c = Canvas.seg_v(c, 0, 0, 2)
    c = Canvas.flip_vertical(Canvas.finalize_mask(c))

    assert lines(c) == ["│", "│", "│AB"]
  end

  test "flip_horizontal mirrors and reverses text runs" do
    c = Canvas.new(7, 3)
    c = Canvas.draw_text(c, "AB", 1, 1, :text)
    c = Canvas.seg_h(c, 1, 0, 6)
    c = Canvas.flip_horizontal(Canvas.finalize_mask(c))

    assert lines(c) == ["────BA─"]
  end

  test "dotted and thick line styles resolve per cell" do
    c = Canvas.new(6, 3)
    c = %{c | cur_style: Canvas.style_dot()}
    c = Canvas.seg_h(c, 0, 0, 5)
    c = %{c | cur_style: Canvas.style_thick()}
    c = Canvas.seg_v(c, 2, 0, 2)

    assert lines(c) == ["╌╌┬╌╌╌", "  ┃", "  ┃"]
  end

  test "to_lines trims blank leading and trailing rows" do
    c = Canvas.new(3, 5)
    c = Canvas.draw_text(c, "x", 0, 2, :text)

    assert lines(c) == ["x"]
  end

  test "mask_char covers the box-drawing alphabet" do
    # U
    assert Canvas.mask_char(1) == "│"
    # D
    assert Canvas.mask_char(2) == "│"
    # U|D
    assert Canvas.mask_char(3) == "│"
    # L
    assert Canvas.mask_char(4) == "─"
    # R
    assert Canvas.mask_char(8) == "─"
    # L|R
    assert Canvas.mask_char(12) == "─"
    # D|R
    assert Canvas.mask_char(10) == "┌"
    # D|L
    assert Canvas.mask_char(6) == "┐"
    # U|R
    assert Canvas.mask_char(9) == "└"
    # U|L
    assert Canvas.mask_char(5) == "┘"
    # U|D|R
    assert Canvas.mask_char(11) == "├"
    # U|D|L
    assert Canvas.mask_char(7) == "┤"
    # D|L|R
    assert Canvas.mask_char(14) == "┬"
    # U|L|R
    assert Canvas.mask_char(13) == "┴"
    assert Canvas.mask_char(15) == "┼"
  end
end
