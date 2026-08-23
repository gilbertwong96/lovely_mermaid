defmodule GrokMermaid.Labels do
  @moduledoc """
  Label text helpers, ported from grok-mermaid's labels.ts: control
  stripping, HTML entity decoding, markdown/HTML tag stripping, and
  width-aware wrapping and truncation.
  """

  alias GrokMermaid.Width

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
    s
    |> String.graphemes()
    |> Enum.reduce({"", false}, fn c, {out, open} ->
      if c == "~" do
        {out <> if(open, do: ">", else: "<"), not open}
      else
        {out <> c, open}
      end
    end)
    |> elem(0)
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
  def is_alphanumeric(c), do: String.match?(c, ~r/[\p{Alphabetic}\p{N}]/u)

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
      decode_pass(String.graphemes(s), 0, "")
    end
  end

  defp decode_pass(chars, i, out) when i >= length(chars), do: out

  defp decode_pass(chars, i, out) do
    if Enum.at(chars, i) != "&" do
      decode_pass(chars, i + 1, out <> Enum.at(chars, i))
    else
      hi = min(i + 1 + @entity_lookahead, length(chars))
      semi = find_semi(chars, i + 1, hi)

      body = if semi == -1, do: nil, else: Enum.slice(chars, i + 1, semi - i - 1) |> Enum.join()

      case body && decode_entity_body(body) do
        {:ok, decoded} -> decode_pass(chars, semi + 1, out <> decoded)
        _ -> decode_pass(chars, i + 1, out <> "&")
      end
    end
  end

  defp find_semi(chars, from, hi) do
    Enum.reduce_while(from..(hi - 1)//1, -1, fn j, _acc ->
      if Enum.at(chars, j) == ";", do: {:halt, j}, else: {:cont, -1}
    end)
  end

  # --- Markdown / HTML stripping -------------------------------------------

  @doc "Strip markdown emphasis from a `` `backtick` `` label string."
  @spec strip_markdown(String.t()) :: String.t()
  def strip_markdown(s) do
    no_code = s |> String.graphemes() |> Enum.reject(&(&1 == "`")) |> Enum.join()
    no_strong = no_code |> String.replace("**", "") |> String.replace("__", "")
    chars = String.graphemes(no_strong)

    out =
      Enum.with_index(chars)
      |> Enum.reduce("", fn {c, i}, out ->
        in_word =
          i > 0 and is_alphanumeric(Enum.at(chars, i - 1)) and
            i + 1 < length(chars) and is_alphanumeric(Enum.at(chars, i + 1))

        if (c == "*" or c == "_") and not in_word, do: out, else: out <> c
      end)

    String.trim(out)
  end

  @doc """
  Inline formatting tags that carry no meaning in a terminal are removed;
  anything else that looks like a tag (`Vec<String>`, `<id>`) is left alone.
  """
  @spec strip_html_tags(String.t()) :: String.t()
  def strip_html_tags(s) do
    s |> String.graphemes() |> scan_tags(0, "")
  end

  defp scan_tags(chars, i, out) when i >= length(chars), do: out

  defp scan_tags(chars, i, out) do
    if Enum.at(chars, i) == "<" do
      case html_tag_at(chars, i) do
        {:ok, name, end_idx} ->
          cond do
            String.downcase(name) == "br" -> scan_tags(chars, end_idx, out <> " ")
            String.downcase(name) in @formatting_tags -> scan_tags(chars, end_idx, out)
            true -> scan_tags(chars, i + 1, out <> "<")
          end

        nil ->
          scan_tags(chars, i + 1, out <> "<")
      end
    else
      scan_tags(chars, i + 1, out <> Enum.at(chars, i))
    end
  end

  # Read a tag starting at `start`, returning its name and the index after
  # the closing `>`.
  defp html_tag_at(chars, start) do
    i = start + 1
    i = if Enum.at(chars, i) == "/", do: i + 1, else: i
    name_start = i

    i =
      Enum.reduce_while(i..(length(chars) - 1)//1, i, fn _, acc ->
        c = Enum.at(chars, acc)

        if c != nil and String.match?(c, ~r/^[0-9A-Za-z]$/) do
          {:cont, acc + 1}
        else
          {:halt, acc}
        end
      end)

    if i == name_start do
      nil
    else
      name = Enum.slice(chars, name_start, i - name_start) |> Enum.join()

      case scan_to_gt(chars, i) do
        {:ok, gt} -> {:ok, name, gt + 1}
        :error -> nil
      end
    end
  end

  defp scan_to_gt(chars, i) do
    Enum.reduce_while(i..(length(chars) - 1)//1, :error, fn i, _ ->
      case Enum.at(chars, i) do
        ">" -> {:halt, {:ok, i}}
        "<" -> {:halt, :error}
        _ -> {:cont, :error}
      end
    end)
  end

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

  # Break an over-wide word after the last fitting identifier boundary,
  # falling back to a per-character break when it has none.
  defp break_word(word, width, chunk, chunk_w) do
    {lines, chunk, chunk_w} =
      Enum.reduce(Width.measured(word), {[], chunk, chunk_w}, fn {ch, cw},
                                                                 {lines, chunk, chunk_w} ->
        if chunk_w + cw > width and chunk != "" do
          p = last_break(chunk)

          carry = if p == -1, do: "", else: String.slice(chunk, (p + 1)..-1//1)
          piece = if p == -1, do: chunk, else: String.slice(chunk, 0..p//1)

          # the current character joins the new chunk (TS: `chunk += ch` after the break)
          {lines ++ [piece], carry <> ch, Width.string_width(carry) + cw}
        else
          {lines, chunk <> ch, chunk_w + cw}
        end
      end)

    {lines ++ [chunk], chunk, chunk_w}
  end

  defp fit_to_width(s, target) do
    {out, _} =
      Enum.reduce_while(Width.measured(s), {"", 0}, fn {ch, cw}, {out, used} ->
        if used + cw > target do
          {:halt, {out, used}}
        else
          {:cont, {out <> ch, used + cw}}
        end
      end)

    out
  end

  @doc "Truncate to `inner` columns, leaving room for the ellipsis."
  @spec fit_label(String.t(), non_neg_integer()) :: String.t()
  def fit_label(label, inner) do
    if Width.string_width(label) <= inner do
      label
    else
      {out, _} =
        Enum.reduce_while(Width.measured(label), {"", 0}, fn {c, cw}, {out, used} ->
          if used + cw + 1 > inner do
            {:halt, {out, used}}
          else
            {:cont, {out <> c, used + cw}}
          end
        end)

      out <> "…"
    end
  end
end
