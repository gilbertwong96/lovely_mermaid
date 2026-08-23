defmodule LovelyMermaid.Labels do
  @moduledoc """
  Label text helpers, ported from lovely-mermaid's labels.ts: control
  stripping, HTML entity decoding, markdown/HTML tag stripping, and
  width-aware wrapping and truncation.
  """

  alias LovelyMermaid.Width

  # Node labels wrap to at most this many display columns per line ...
  @wrap_width 24
  # ... and at most this many lines; overflow is truncated with an ellipsis.
  @max_lines 4
  # Edge labels are truncated to this many columns.
  @max_label 28

  # Identifier-boundary characters preferred as break points when a single
  # word is too wide to fit, so it is not sliced mid-segment.
  @label_break_chars ~w(_ - . /)

  @entity_lookahead 10

  @named_entities %{
    "lt" => "<",
    "gt" => ">",
    "amp" => "&",
    "quot" => "\"",
    "apos" => "'"
  }

  @formatting_tags MapSet.new(~w(
    b strong i em u s strike del ins mark small big sub sup code kbd samp
    var tt span font q abbr cite pre
  ))

  @doc "Node labels wrap to at most this many columns per line."
  def wrap_width, do: @wrap_width

  @doc "Labels wrap to at most this many lines before the ellipsis."
  def max_lines, do: @max_lines

  @doc "Edge labels are truncated to this many columns."
  def max_label, do: @max_label

  @doc "ASCII-only case folding, matching Rust's `to_ascii_lowercase`."
  @spec ascii_lower(String.t()) :: String.t()
  def ascii_lower(s), do: String.replace(s, ~r/[A-Z]/, &String.downcase/1)

  @doc "ASCII-only case folding."
  @spec ascii_upper(String.t()) :: String.t()
  def ascii_upper(s), do: String.replace(s, ~r/[a-z]/, &String.upcase/1)

  # C0 and C1 controls, less `\t\n\r` the parsers read. NUL collides with
  # the CONT sentinel and ESC would inject ANSI into scrollback.
  @controls ~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/

  @doc "Mermaid writes generics as `List~T~`; show them as `List<T>`."
  @spec display_generics(String.t()) :: String.t()
  def display_generics(s) do
    {out, _} =
      s
      |> String.graphemes()
      |> Enum.reduce({[], false}, fn c, {out, open} ->
        if c == "~" do
          {[if(open, do: ">", else: "<") | out], not open}
        else
          {[c | out], open}
        end
      end)

    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @doc "Strip ANSI SGR sequences and other control chars from a label."
  @spec strip_controls(String.t()) :: String.t()
  def strip_controls(src), do: String.replace(src, @controls, "")

  @doc """
  Split source into lines like Rust's `str::lines()`: on `\\n`, with a
  trailing `\\r` stripped, and without a final empty line when the input
  ends in a newline.
  """
  @spec src_lines(String.t()) :: [String.t()]
  def src_lines(src) do
    src
    |> String.split("\n")
    |> Enum.map(fn l ->
      if String.ends_with?(l, "\r"), do: String.trim_trailing(l, "\r"), else: l
    end)
    |> then(fn lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines end)
  end

  @doc "Matches Rust's `char::is_alphanumeric`."
  @spec is_alphanumeric(String.t()) :: boolean()
  def is_alphanumeric(c), do: String.match?(c, ~r/[\p{Xan}]/u)

  @doc "Characters allowed in a bare node/state/class identifier."
  @spec is_id_char(String.t()) :: boolean()
  def is_id_char(c), do: is_alphanumeric(c) or c == "_"

  # --- HTML entities --------------------------------------------------------

  defp decode_entity_body(body) do
    cond do
      Map.has_key?(@named_entities, body) ->
        {:ok, Map.fetch!(@named_entities, body)}

      String.starts_with?(body, "#") ->
        num = String.slice(body, 1..-1//1)
        hex = String.match?(num, ~r/^[xX]/)
        digits = if hex, do: String.slice(num, 1..-1//1), else: num

        valid_digits? =
          if hex,
            do: String.match?(digits, ~r/^[0-9a-fA-F]+$/),
            else: String.match?(digits, ~r/^[0-9]+$/)

        if valid_digits? do
          code = String.to_integer(digits, if(hex, do: 16, else: 10))

          cond do
            code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) -> :error
            code < 0x20 or (code >= 0x7F and code <= 0x9F) -> :error
            true -> {:ok, <<code::utf8>>}
          end
        else
          :error
        end

      true ->
        :error
    end
  end

  @doc """
  Decode HTML entities in label text. The single pass never re-scans
  emitted text, so `&amp;lt;` decodes to `&lt;` rather than to `<`.
  """
  @spec decode_html_entities(String.t()) :: String.t()
  def decode_html_entities(s) do
    if not String.contains?(s, "&") do
      s
    else
      decode_pass(String.graphemes(s), "")
    end
  end

  defp decode_pass([], out), do: out

  defp decode_pass([c | rest], out) do
    if c != "&" do
      decode_pass(rest, out <> c)
    else
      {body, rest2} = take_entity(rest, [])

      case body && decode_entity_body(body) do
        {:ok, decoded} -> decode_pass(rest2, out <> decoded)
        _ -> decode_pass(rest, out <> "&")
      end
    end
  end

  # Up to @entity_lookahead chars until `;`; `nil` when none closes it.
  defp take_entity(chars, acc) do
    if length(acc) >= @entity_lookahead do
      {nil, chars}
    else
      case chars do
        [";" | rest] -> {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
        [c | rest] -> take_entity(rest, [c | acc])
        [] -> {nil, []}
      end
    end
  end

  # --- Markdown / HTML stripping -------------------------------------------

  @doc "Strip markdown emphasis from a `` `backtick` `` label string."
  @spec strip_markdown(String.t()) :: String.t()
  def strip_markdown(s) do
    no_code = s |> String.graphemes() |> Enum.reject(&(&1 == "`")) |> Enum.join()
    no_strong = no_code |> String.replace("**", "") |> String.replace("__", "")
    chars = no_strong |> String.graphemes() |> List.to_tuple()

    out =
      chars
      |> Tuple.to_list()
      |> Stream.with_index()
      |> Enum.reduce([], fn {c, i}, out ->
        in_word =
          i > 0 and is_alphanumeric(elem(chars, i - 1)) and
            i + 1 < tuple_size(chars) and is_alphanumeric(elem(chars, i + 1))

        if (c == "*" or c == "_") and not in_word, do: out, else: [c | out]
      end)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    String.trim(out)
  end

  @doc """
  Inline formatting tags that carry no meaning in a terminal are removed;
  anything else that looks like a tag (`Vec<String>`, `<id>`) is left alone.
  """
  @spec strip_html_tags(String.t()) :: String.t()
  def strip_html_tags(s) do
    s |> String.graphemes() |> scan_tags("")
  end

  defp scan_tags([], out), do: out

  defp scan_tags([c | rest], out) do
    if c == "<" do
      case html_tag_at([c | rest]) do
        {:ok, name, tail} ->
          cond do
            String.downcase(name) == "br" -> scan_tags(tail, out <> " ")
            String.downcase(name) in @formatting_tags -> scan_tags(tail, out)
            true -> scan_tags(rest, out <> "<")
          end

        nil ->
          scan_tags(rest, out <> "<")
      end
    else
      scan_tags(rest, out <> c)
    end
  end

  # Read a tag at the head of `chars`, returning its name and the tail
  # after the closing `>`.
  defp html_tag_at(["<" | rest]) do
    chars =
      case rest do
        ["/" | rest2] -> rest2
        _ -> rest
      end

    {name_chars, rest} = take_tag_name(chars, [])

    if name_chars == [] do
      nil
    else
      case scan_to_gt(rest) do
        {:ok, tail} -> {:ok, name_chars |> Enum.reverse() |> IO.iodata_to_binary(), tail}
        :error -> nil
      end
    end
  end

  defp take_tag_name([c | rest], acc) do
    if String.match?(c, ~r/^[0-9A-Za-z]$/) do
      take_tag_name(rest, [c | acc])
    else
      {acc, [c | rest]}
    end
  end

  defp take_tag_name([], acc), do: {acc, []}

  defp scan_to_gt([">" | rest]), do: {:ok, rest}
  defp scan_to_gt(["<" | _]), do: :error
  defp scan_to_gt([_ | rest]), do: scan_to_gt(rest)
  defp scan_to_gt([]), do: :error

  defp unwrap(s, open, close) do
    if String.length(s) >= String.length(open) + String.length(close) and
         String.starts_with?(s, open) and String.ends_with?(s, close) do
      {:ok, String.slice(s, String.length(open)..(String.length(s) - String.length(close) - 1))}
    else
      :error
    end
  end

  @doc """
  Normalise raw label text: strip markup, unquote, and decode entities.
  Decoding happens after tag-stripping so `<b>` is removed as markup while
  `&lt;b&gt;` survives as the literal text `<b>`.
  """
  @spec clean_label(String.t()) :: String.t()
  def clean_label(raw) do
    trimmed = raw |> String.trim() |> strip_html_tags() |> String.trim()

    unquoted =
      case unwrap(trimmed, "\"", "\"") do
        {:ok, inner} ->
          String.trim(inner)

        :error ->
          case unwrap(trimmed, "'", "'") do
            {:ok, inner} -> String.trim(inner)
            :error -> trimmed
          end
      end

    case unwrap(unquoted, "`", "`") do
      {:ok, md} -> decode_html_entities(strip_markdown(String.trim(md)))
      :error -> decode_html_entities(unquoted)
    end
  end

  # --- Wrapping and truncation ----------------------------------------------

  @doc "Index of the last identifier-boundary character, or -1."
  @spec last_break(String.t()) :: integer()
  def last_break(s) do
    Enum.reduce(@label_break_chars, -1, fn c, best ->
      case :binary.matches(s, c) do
        [] -> best
        matches -> max(best, matches |> List.last() |> elem(0))
      end
    end)
  end

  @doc """
  Wrap a label to `width` columns over at most `max_lines` lines,
  truncating the last line with an ellipsis if it overflows.
  """
  @spec wrap_label(String.t(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  def wrap_label(label, width, max_lines) do
    width = max(1, width)

    lines =
      label
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({[], "", 0}, &accumulate_word(&1, &2, width))
      |> then(fn {lines, cur, _} -> if cur != "", do: lines ++ [cur], else: lines end)

    lines = if lines == [], do: [""], else: lines

    if length(lines) > max_lines do
      tail = Enum.at(lines, max_lines - 1)
      Enum.take(lines, max_lines - 1) ++ [fit_to_width(tail, max(1, width - 1)) <> "…"]
    else
      lines
    end
  end

  defp accumulate_word(word, {lines, cur, cur_w}, width) do
    ww = Width.string_width(word)

    cond do
      ww > width ->
        lines = if cur != "", do: lines ++ [cur], else: lines
        {broken, chunk, chunk_w} = break_word(word, width, "", 0)
        {lines ++ broken, chunk, chunk_w}

      cur == "" ->
        {lines, word, ww}

      cur_w + 1 + ww <= width ->
        {lines, cur <> " " <> word, cur_w + 1 + ww}

      true ->
        {lines ++ [cur], word, ww}
    end
  end

  defp break_word(word, width, chunk, chunk_w) do
    {lines, chunk, chunk_w} =
      Enum.reduce(Width.measured(word), {[], [chunk], chunk_w}, fn {ch, cw},
                                                                   {lines, chunk, chunk_w} ->
        if chunk_w + cw > width and chunk_w != 0 do
          bin = chunk |> Enum.reverse() |> IO.iodata_to_binary()
          p = last_break(bin)

          {carry, piece, carry_w} =
            if p == -1 do
              {[], bin, 0}
            else
              piece = String.slice(bin, 0..p//1)

              carry =
                bin
                |> String.slice((p + 1)..-1//1)
                |> String.graphemes()
                |> Enum.reverse()

              {carry, piece, chunk_w - Width.string_width(piece)}
            end

          {[piece | lines], [ch | carry], carry_w + cw}
        else
          {lines, [ch | chunk], chunk_w + cw}
        end
      end)

    chunk_bin = chunk |> Enum.reverse() |> IO.iodata_to_binary()
    {Enum.reverse(lines, [chunk_bin]), chunk_bin, chunk_w}
  end

  defp fit_to_width(s, target) do
    {out, _} =
      Enum.reduce_while(Width.measured(s), {[], 0}, fn {ch, cw}, {out, used} ->
        if used + cw > target do
          {:halt, {out, used}}
        else
          {:cont, {[ch | out], used + cw}}
        end
      end)

    out |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @doc "Truncate to `inner` columns, leaving room for the ellipsis."
  @spec fit_label(String.t(), non_neg_integer()) :: String.t()
  def fit_label(label, inner) do
    if Width.string_width(label) <= inner do
      label
    else
      {out, _} =
        Enum.reduce_while(Width.measured(label), {[], 0}, fn {c, cw}, {out, used} ->
          if used + cw + 1 > inner do
            {:halt, {out, used}}
          else
            {:cont, {[c | out], used + cw}}
          end
        end)

      (out |> Enum.reverse() |> IO.iodata_to_binary()) <> "…"
    end
  end
end
