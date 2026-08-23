defmodule LovelyMermaid.WidthTest do
  use ExUnit.Case, async: true

  alias LovelyMermaid.Width

  test "ascii and CJK widths" do
    assert Width.string_width("a") == 1
    assert Width.string_width("中") == 2
    assert Width.string_width("a中") == 3
    # fullwidth space
    assert Width.string_width("　") == 2
  end

  test "zero-width code points occupy nothing" do
    # soft hyphen and zero-width space
    assert Width.string_width("\u00ad") == 0
    assert Width.string_width("\u200b") == 0
  end

  test "variation selector forces emoji presentation to two columns" do
    # VS16 alone is two columns; a heart plus VS16 stays two
    assert Width.string_width("\ufe0f") == 2
    assert Width.string_width("❤\ufe0f") == 2
  end

  test "regional indicator pairs (flags) count two columns" do
    assert Width.string_width("\u{1F1E8}\u{1F1F3}") == 2
  end

  test "grapheme clusters stay whole (ZWJ family emoji)" do
    family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}"
    assert [^family] = Width.clusters(family)
    assert Width.string_width(family) == 2
  end

  test "combining marks measure as the base" do
    assert Width.string_width("é") == 1
    assert Width.string_width("e\u0301") == 1
  end

  test "cluster_width takes the widest code point" do
    assert Width.cluster_width("a") == 1
    assert Width.cluster_width("中") == 2
    assert Width.cluster_width("👍") == 2
  end

  test "measured returns clusters with their widths" do
    assert Width.measured("a中") == [{"a", 1}, {"中", 2}]
  end

  test "code_point_width covers the whole code point space" do
    # spot checks across the table: ASCII, combining, CJK, private use, max
    assert Width.code_point_width(0x41) == 1
    assert Width.code_point_width(0x300) == 0
    assert Width.code_point_width(0x4E00) == 2
    assert Width.code_point_width(0x10FFFF) == 1
  end
end
