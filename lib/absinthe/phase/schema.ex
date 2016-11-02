defmodule Absinthe.Phase.Schema do

  @moduledoc false

  # Populate all schema nodes and the adapter for the blueprint tree. If the
  # blueprint tree is a _schema_ tree, this schema is the meta schema (source of
  # IDL directives, etc).
  #
  # Note that no validation occurs in this phase.

  use Absinthe.Phase

  alias Absinthe.{Blueprint, Type, Schema}

  # The approach here is pretty simple.
  # We start at the top blueprint node and set the appropriate schema node on operations
  # directives and so forth.
  #
  # Then, as `prewalk` walks down the tree we hit a node. If that node has a schema_node
  # set by its parent, we walk to its children and set the schema node on those children.
  # We do not need to walk any further because `prewalk` will do that for us.
  #
  # Thus at each node we need only concern ourselves with immediate children.
  @spec run(Blueprint.t, Keyword.t) :: {:ok, Blueprint.t}
  def run(input, options \\ []) do
    schema = Keyword.fetch!(options, :schema)
    adapter = Keyword.get(options, :adapter, Absinthe.Adapter.LanguageConventions)

    result = Blueprint.prewalk(input, &handle_node(&1, schema, adapter))
    {:ok, result}
  end

  defp handle_node(%Blueprint{} = node, schema, adapter) do
    set_children %{node | schema: schema, adapter: adapter}, schema, adapter
  end
  defp handle_node(%Absinthe.Blueprint.Document.VariableDefinition{} = node, _, _) do
    {:halt, node}
  end
  defp handle_node(node, schema, adapter) do
    set_children(node, schema, adapter)
  end

  defp set_children(parent, schema, adapter) do
    Blueprint.prewalk(parent, fn
      ^parent -> parent
      %Absinthe.Blueprint.Input.Variable{} = child-> {:halt, child}
      child -> {:halt, set_schema_node(child, parent, schema, adapter)}
    end)
  end

  # Do note, the `parent` arg is the parent blueprint node, not the parent's schema node.
  defp set_schema_node(%Blueprint.Document.Fragment.Inline{type_condition: %{name: type_name}} = node, _parent, schema, _adapter) do
    %{node | schema_node: schema.__absinthe_type__(type_name)}
  end
  defp set_schema_node(%Blueprint.Directive{name: name} = node, _parent, schema, adapter) do
    schema_node =
      name
      |> adapter.to_internal_name(:directive)
      |> schema.__absinthe_directive__

    %{node | schema_node: schema_node}
  end
  defp set_schema_node(%Blueprint.Document.Operation{type: op_type} = node, _parent, schema, _adapter) do
    %{node | schema_node: schema.__absinthe_type__(op_type)}
  end
  defp set_schema_node(%Blueprint.Document.Fragment.Named{} = node, _parent, schema, _adapter) do
    %{node | schema_node: schema.__absinthe_type__(node.type_condition.name)}
  end
  defp set_schema_node(%Blueprint.Document.VariableDefinition{type: type_reference} = node, _parent, schema, _adapter) do
    wrapped =
      type_reference
      |> type_reference_to_type(schema)

    wrapped
    |> Type.unwrap
    |> case do
      nil -> node
      _ -> %{node | schema_node: wrapped}
    end
  end
  defp set_schema_node(node, %{schema_node: nil}, _, _) do
    # if we don't know the parent schema node, and we aren't one of the earlier nodes,
    # then we can't know our schema node.
    node
  end
  defp set_schema_node(%Blueprint.Document.Fragment.Inline{type_condition: nil} = node, parent, schema, adapter) do
    type = case parent.schema_node do
        %{type: type} -> type
        other -> other
      end
      |> Type.expand(schema)
      |> Type.unwrap

    set_schema_node(%{node | type_condition: %Blueprint.TypeReference.Name{name: type.name}}, parent, schema, adapter)
  end
  defp set_schema_node(%Blueprint.Document.Field{} = node, parent, schema, adapter) do
    %{node | schema_node: find_schema_field(parent.schema_node, node.name, schema, adapter)}
  end
  defp set_schema_node(%Blueprint.Input.Argument{name: name} = node, parent, _schema, adapter) do
    %{node | schema_node: find_schema_argument(parent.schema_node, name, adapter)}
  end
  defp set_schema_node(%Blueprint.Document.Fragment.Spread{} = node, _, _, _) do
    node
  end
  defp set_schema_node(%Blueprint.Input.Field{} = node, parent, schema, adapter) do
    %{node | schema_node: find_schema_field(parent.schema_node, node.name, schema, adapter)}
  end
  defp set_schema_node(%Blueprint.Input.Value{} = node, parent, schema, _) do
    case parent.schema_node do
      %Type.Argument{type: type} ->
        %{node | schema_node: type |> Type.expand(schema)}
      %Absinthe.Type.Field{type: type} ->
        %{node | schema_node: type |> Type.expand(schema)}
      type ->
        %{node | schema_node: type |> Type.expand(schema)}
    end
  end
  defp set_schema_node(node, %Blueprint.Input.Value{normalized: nil}, _schema, _) do
    node
  end
  defp set_schema_node(%{schema_node: nil} = node, %Blueprint.Input.Value{} = parent, _schema, _) do
    %{node | schema_node: Type.unwrap(parent.schema_node)}
  end
  defp set_schema_node(nil, _, _, _) do
    nil
  end
  defp set_schema_node(node, _, _schema, _) do
    node
  end

  # Given a schema field or directive, lookup a child argument definition
  @spec find_schema_argument(nil | Type.Field.t | Type.Argument.t, String.t, Absinthe.Adapter.t) :: nil | Type.Argument.t
  defp find_schema_argument(%{args: arguments}, name, adapter) do
    internal_name = adapter.to_internal_name(name, :argument)
    arguments
    |> Map.values
    |> Enum.find(&match?(%{name: ^internal_name}, &1))
  end

  # Given a schema type, lookup a child field definition
  @spec find_schema_field(nil | Type.t, String.t, Absinthe.Schema.t, Absinthe.Adapter.t) :: nil | Type.Field.t
  defp find_schema_field(_, "__" <> introspection_field, _, _) do
    Absinthe.Introspection.Field.meta(introspection_field)
  end
  defp find_schema_field(%{of_type: type}, name, schema, adapter) do
    find_schema_field(type, name, schema, adapter)
  end
  defp find_schema_field(%{fields: fields}, name, _schema, adapter) do
    internal_name = adapter.to_internal_name(name, :field)
    fields
    |> Map.values
    |> Enum.find(&match?(%{name: ^internal_name}, &1))
  end
  defp find_schema_field(%Type.Field{type: maybe_wrapped_type}, name, schema, adapter) do
    type = Type.unwrap(maybe_wrapped_type)
    |> schema.__absinthe_type__
    find_schema_field(type, name, schema, adapter)
  end
  defp find_schema_field(_, _, _, _) do
    nil
  end

  @type_mapping %{
    Blueprint.TypeReference.List => Type.List,
    Blueprint.TypeReference.NonNull => Type.NonNull
  }
  defp type_reference_to_type(%Blueprint.TypeReference.Name{} = node, schema) do
    Schema.lookup_type(schema, node.name)
  end
  for {blueprint_type, core_type} <- @type_mapping do
    defp type_reference_to_type(%unquote(blueprint_type){} = node, schema) do
      inner = type_reference_to_type(node.of_type, schema)
      %unquote(core_type){of_type: inner}
    end
  end
end