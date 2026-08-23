defmodule GrokMermaid.Graph do
  @moduledoc """
  The shared diagram model, ported from grok-mermaid's graph.ts.

  Flowchart, state, class and ER sources all parse into a `Graph`; only
  sequence diagrams have their own model.
  """

  # Caps that keep layout bounded; exceeding one drops the diagram to fallback.
  @max_nodes 128
  @max_edges 512
  @max_groups 24
  @max_group_depth 6
  # Class members / ER attributes listed per box before eliding with `…`.
  @max_members 8

  defmodule Node do
    @moduledoc false
    defstruct [:label, :shape, :classes, :href]
  end

  defmodule Edge do
    @moduledoc false
    defstruct [:from, :to, :label, :head_to, :head_from, :line]
  end

  defmodule Group do
    @moduledoc false
    defstruct [:id, :label, :parent]
  end

  defmodule ClassInfo do
    @moduledoc false
    defstruct [:annotation, :attrs, :methods]
  end

  defstruct nodes: [],
            edges: [],
            index: %{},
            groups: [],
            # Innermost subgraph each node was declared in, parallel to nodes.
            node_group: [],
            cur_group: nil,
            # Nesting depth of the current subgraph (stack height in the TS).
            subgraph_depth: 0,
            # Set when a cap was hit; the caller abandons the parse.
            over_cap: false,
            # Text the flowchart grammar could not read and silently discarded.
            warnings: [],
            # Parsed `classDef` declarations: name -> property map.
            class_defs: %{},
            dir: :down

  @type shape :: :rect | :round | :diamond
  @type head :: :none | :arrow | :circle | :cross | :triangle | :diamond_fill | :diamond_open
  @type line_kind :: :solid | :dotted | :thick
  @type dir :: :down | :up | :right | :left

  @type node_t :: %Node{
          label: String.t(),
          shape: shape(),
          # Author classes, from `:::name` or `class A,B name`; carried out
          # through `Span.classes`.
          classes: [String.t()],
          # Link target from `click A "url"` / `link A "url"`, carried out
          # through `Span.href`.
          href: String.t() | nil
        }

  @type edge :: %Edge{
          from: non_neg_integer(),
          to: non_neg_integer(),
          label: String.t() | nil,
          head_to: head(),
          head_from: head(),
          line: line_kind()
        }

  @type group :: %Group{id: String.t(), label: String.t(), parent: non_neg_integer() | nil}

  @type class_info :: %ClassInfo{
          annotation: String.t() | nil,
          attrs: [String.t()],
          methods: [String.t()]
        }

  @type t :: %__MODULE__{class_defs: map()}

  @doc "Caps that keep layout bounded."
  def max_nodes, do: @max_nodes
  def max_edges, do: @max_edges
  def max_groups, do: @max_groups
  def max_group_depth, do: @max_group_depth
  def max_members, do: @max_members

  @doc "Empty class/ER box compartment info."
  @spec empty_class_info() :: class_info()
  def empty_class_info, do: %ClassInfo{annotation: nil, attrs: [], methods: []}

  @doc """
  `LR`/`RL`/`BT` as written in a header or `direction` statement; else
  `:down`.
  """
  @spec parse_dir(String.t()) :: dir()
  def parse_dir(token) do
    case GrokMermaid.Labels.ascii_upper(token) do
      "LR" -> :right
      "RL" -> :left
      "BT" -> :up
      _ -> :down
    end
  end

  @doc "Create an empty graph with a direction."
  @spec new(dir()) :: t()
  def new(dir \\ :down), do: %__MODULE__{dir: dir}

  @doc """
  Index of `id`, creating the node if new. A later declaration carrying a
  label overwrites the placeholder one an edge created. Returns `nil` once
  `MAX_NODES` is reached, which aborts the parse.
  """
  @spec node_index(t(), String.t(), String.t() | nil, shape()) :: {t(), non_neg_integer() | nil}
  def node_index(%__MODULE__{} = graph, id, label, shape) do
    case Map.fetch(graph.index, id) do
      {:ok, existing} ->
        if label != nil do
          nodes =
            List.update_at(graph.nodes, existing, fn n -> %{n | label: label, shape: shape} end)

          {%{graph | nodes: nodes}, existing}
        else
          {graph, existing}
        end

      :error ->
        if length(graph.nodes) >= @max_nodes do
          {%{graph | over_cap: true}, nil}
        else
          index = Map.put(graph.index, id, length(graph.nodes))
          nodes = graph.nodes ++ [%Node{label: label || id, shape: shape, classes: [], href: nil}]
          node_group = graph.node_group ++ [graph.cur_group]
          {%{graph | index: index, nodes: nodes, node_group: node_group}, length(nodes) - 1}
        end
    end
  end

  @doc "Set a node's label without disturbing its shape, creating it if new."
  @spec node_label(t(), String.t(), String.t()) :: {t(), non_neg_integer() | nil}
  def node_label(%__MODULE__{} = graph, id, label) do
    case Map.fetch(graph.index, id) do
      {:ok, existing} ->
        nodes = List.update_at(graph.nodes, existing, fn n -> %{n | label: label} end)
        {%{graph | nodes: nodes}, existing}

      :error ->
        node_index(graph, id, label, :round)
    end
  end

  @doc "Append an edge, or flag `over_cap` when `MAX_EDGES` is reached."
  @spec push_edge(t(), edge()) :: {t(), boolean()}
  def push_edge(%__MODULE__{} = graph, edge) do
    if length(graph.edges) >= @max_edges do
      {%{graph | over_cap: true}, false}
    else
      {%{graph | edges: graph.edges ++ [edge]}, true}
    end
  end

  @doc "Attach an author class name to a node, ignoring a repeat."
  @spec add_class(t(), non_neg_integer(), String.t()) :: t()
  def add_class(%__MODULE__{} = graph, idx, name) do
    node = Enum.at(graph.nodes, idx)

    if name in node.classes do
      graph
    else
      nodes = List.update_at(graph.nodes, idx, fn n -> %{n | classes: n.classes ++ [name]} end)
      %{graph | nodes: nodes}
    end
  end

  @doc """
  Apply collected `[ids, names]` class assignments. Run after the statement
  walk so a `class A,B name` (or `:::` tag) may precede the nodes it names;
  unknown ids are ignored.
  """
  @spec apply_classes(t(), [{String.t(), [String.t()]}]) :: t()
  def apply_classes(%__MODULE__{} = graph, assignments) do
    Enum.reduce(assignments, graph, fn {ids, names}, graph ->
      Enum.reduce(ids, graph, fn id, graph ->
        id = String.trim(id)

        case Map.fetch(graph.index, id) do
          {:ok, idx} -> Enum.reduce(names, graph, &add_class(&2, idx, &1))
          :error -> graph
        end
      end)
    end)
  end

  @doc """
  Apply `[id, url]` link targets; the last one per id wins, unknown ids are
  ignored. Deferred like `apply_classes`, for the same ordering reason.
  """
  @spec apply_hrefs(t(), [{String.t(), String.t()}]) :: t()
  def apply_hrefs(%__MODULE__{} = graph, hrefs) do
    Enum.reduce(hrefs, graph, fn {id, url}, graph ->
      id = String.trim(id)

      case Map.fetch(graph.index, id) do
        {:ok, idx} ->
          nodes = List.update_at(graph.nodes, idx, fn n -> %{n | href: url} end)
          %{graph | nodes: nodes}

        :error ->
          graph
      end
    end)
  end
end
