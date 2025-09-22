defmodule ReqLLM.Schema do
  @moduledoc """
  Single schema authority for NimbleOptions ↔ JSON Schema conversion.

  This module consolidates all schema conversion logic, providing unified functions
  for converting keyword schemas to both NimbleOptions compiled schemas and JSON Schema format.
  Supports all common NimbleOptions types and handles nested schemas.

  ## Core Functions

  - `compile/1` - Convert keyword schema to NimbleOptions compiled schema
  - `to_json/1` - Convert keyword schema to JSON Schema format  


  ## Basic Usage

      # Compile keyword schema to NimbleOptions
      {:ok, compiled} = ReqLLM.Schema.compile([
        name: [type: :string, required: true, doc: "User name"],
        age: [type: :pos_integer, doc: "User age"]
      ])

      # Convert keyword schema to JSON Schema
      json_schema = ReqLLM.Schema.to_json([
        name: [type: :string, required: true, doc: "User name"], 
        age: [type: :pos_integer, doc: "User age"]
      ])
      # => %{
      #      "type" => "object",
      #      "properties" => %{
      #        "name" => %{"type" => "string", "description" => "User name"},
      #        "age" => %{"type" => "integer", "minimum" => 1, "description" => "User age"}
      #      },
      #      "required" => ["name"]
      #    }



  ## Supported Types

  All common NimbleOptions types are supported:

  - `:string` - String type
  - `:integer` - Integer type
  - `:pos_integer` - Positive integer (adds minimum: 1 constraint)
  - `:float` - Float/number type
  - `:number` - Generic number type
  - `:boolean` - Boolean type
  - `{:list, type}` - Array of specified type
  - `:map` - Object type
  - Custom types fall back to string

  ## Nested Schemas

  Nested schemas are supported through recursive type handling:

      schema = [
        user: [
          type: {:list, :map},
          doc: "List of user objects",
          properties: [
            name: [type: :string, required: true],
            email: [type: :string, required: true]
          ]
        ]
      ]

  """

  @doc """
  Compiles a keyword schema to a NimbleOptions compiled schema.

  Takes a keyword list representing a NimbleOptions schema and compiles it
  into a validated NimbleOptions schema that can be used for validation.

  ## Parameters

  - `schema` - A keyword list representing a NimbleOptions schema

  ## Returns

  - `{:ok, compiled_schema}` - Successfully compiled NimbleOptions schema
  - `{:error, error}` - Compilation error with details

  ## Examples

      iex> ReqLLM.Schema.compile([
      ...>   name: [type: :string, required: true],
      ...>   age: [type: :pos_integer, default: 0]
      ...> ])
      {:ok, compiled_schema}

      iex> ReqLLM.Schema.compile("invalid")
      {:error, %ReqLLM.Error.Invalid.Parameter{}}

  """
  @spec compile(keyword() | any()) :: {:ok, map()} | {:error, ReqLLM.Error.t()}
  def compile(schema) when is_list(schema) do
    # Pre-process schema to handle nested schemas with :properties
    processed_schema = preprocess_nested_schema(schema)

    # Create a custom compiled schema that stores both the original and processed versions
    compiled = %{
      schema: schema,
      processed_schema: processed_schema,
      nimble_schema: NimbleOptions.new!(processed_schema)
    }

    {:ok, compiled}
  rescue
    e ->
      {:error,
       ReqLLM.Error.Validation.Error.exception(
         tag: :invalid_schema,
         reason: "Invalid schema: #{Exception.message(e)}",
         context: [schema: schema]
       )}
  end

  def compile(schema) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "Schema must be a keyword list, got: #{inspect(schema)}"
     )}
  end

  # Preprocess schema to convert nested :properties into NimbleOptions-compatible format
  defp preprocess_nested_schema(schema) do
    Enum.map(schema, fn {key, opts} ->
      processed_opts =
        case opts do
          opts when is_list(opts) ->
            opts
            # Convert custom types to NimbleOptions-compatible types FIRST (before deleting :items)
            |> convert_object_types()
            # Then remove nested schema options that NimbleOptions doesn't understand
            # For object types
            |> Keyword.delete(:properties)
            # For array types
            |> Keyword.delete(:items)

          _ ->
            opts
        end

      {key, processed_opts}
    end)
  end

  # Convert custom types to NimbleOptions-compatible types
  defp convert_object_types(opts) do
    case opts[:type] do
      :object ->
        Keyword.put(opts, :type, :map)

      :array ->
        # Convert :array with :items to {:list, subtype}
        case opts[:items] do
          [type: item_type] -> Keyword.put(opts, :type, {:list, item_type})
          _ -> Keyword.put(opts, :type, {:list, :any})
        end

      {:list, :object} ->
        Keyword.put(opts, :type, {:list, :map})

      _ ->
        opts
    end
  end

  @doc """
  Converts a keyword schema to JSON Schema format.

  Takes a keyword list of parameter definitions and converts them to
  a JSON Schema object suitable for LLM tool definitions or structured data schemas.

  ## Parameters

  - `schema` - Keyword list of parameter definitions

  ## Returns

  A map representing the JSON Schema object with properties and required fields.

  ## Examples

      iex> ReqLLM.Schema.to_json([
      ...>   name: [type: :string, required: true, doc: "User name"],
      ...>   age: [type: :integer, doc: "User age"],
      ...>   tags: [type: {:list, :string}, default: [], doc: "User tags"]
      ...> ])
      %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "User name"},
          "age" => %{"type" => "integer", "description" => "User age"},
          "tags" => %{
            "type" => "array", 
            "items" => %{"type" => "string"}, 
            "description" => "User tags"
          }
        },
        "required" => ["name"]
      }

      iex> ReqLLM.Schema.to_json([])
      %{"type" => "object", "properties" => %{}}

  """
  @spec to_json(keyword() | map()) :: map()
  def to_json([]), do: %{"type" => "object", "properties" => %{}}

  # Handle new compiled schema format
  def to_json(%{original_schema: schema}) when is_list(schema) do
    to_json(schema)
  end

  def to_json(schema) when is_list(schema) do
    {properties, required} =
      Enum.reduce(schema, {%{}, []}, fn {key, opts}, {props_acc, req_acc} ->
        property_name = to_string(key)
        json_prop = nimble_type_to_json_schema(opts[:type] || :string, opts)

        new_props = Map.put(props_acc, property_name, json_prop)
        new_req = if opts[:required], do: [property_name | req_acc], else: req_acc

        {new_props, new_req}
      end)

    schema_object = %{
      "type" => "object",
      "properties" => properties
    }

    if required == [] do
      schema_object
    else
      Map.put(schema_object, "required", Enum.reverse(required))
    end
  end

  # Private helper functions

  # Helper function to add nested properties to an object schema
  defp add_nested_properties(base_schema, properties) when is_list(properties) do
    {nested_properties, required} =
      Enum.reduce(properties, {%{}, []}, fn {key, opts}, {props_acc, req_acc} ->
        property_name = to_string(key)
        json_prop = nimble_type_to_json_schema(opts[:type] || :string, opts)

        new_props = Map.put(props_acc, property_name, json_prop)
        new_req = if opts[:required], do: [property_name | req_acc], else: req_acc

        {new_props, new_req}
      end)

    base_schema
    |> Map.put("properties", nested_properties)
    |> then(fn schema ->
      if required == [] do
        schema
      else
        Map.put(schema, "required", Enum.reverse(required))
      end
    end)
  end

  @spec nimble_type_to_json_schema(atom() | tuple(), keyword()) :: map()
  def nimble_type_to_json_schema(type, opts) do
    base_schema =
      case type do
        :string ->
          %{"type" => "string"}

        :integer ->
          %{"type" => "integer"}

        :pos_integer ->
          %{"type" => "integer", "minimum" => 1}

        :float ->
          %{"type" => "number"}

        :number ->
          %{"type" => "number"}

        :boolean ->
          %{"type" => "boolean"}

        {:list, :string} ->
          %{"type" => "array", "items" => %{"type" => "string"}}

        {:list, :integer} ->
          %{"type" => "array", "items" => %{"type" => "integer"}}

        {:list, :boolean} ->
          %{"type" => "array", "items" => %{"type" => "boolean"}}

        {:list, :float} ->
          %{"type" => "array", "items" => %{"type" => "number"}}

        {:list, :number} ->
          %{"type" => "array", "items" => %{"type" => "number"}}

        {:list, :pos_integer} ->
          %{"type" => "array", "items" => %{"type" => "integer", "minimum" => 1}}

        {:list, :map} ->
          base_items = %{"type" => "object"}

          items_schema =
            case opts[:properties] do
              properties when is_list(properties) ->
                add_nested_properties(base_items, properties)

              _ ->
                base_items
            end

          %{"type" => "array", "items" => items_schema}

        {:list, :object} ->
          base_items = %{"type" => "object"}

          items_schema =
            case opts[:properties] do
              properties when is_list(properties) ->
                add_nested_properties(base_items, properties)

              _ ->
                base_items
            end

          %{"type" => "array", "items" => items_schema}

        {:list, item_type} ->
          %{"type" => "array", "items" => nimble_type_to_json_schema(item_type, [])}

        :map ->
          base_schema = %{"type" => "object"}
          # Check if this map has nested properties defined
          case opts[:properties] do
            properties when is_list(properties) ->
              add_nested_properties(base_schema, properties)

            _ ->
              base_schema
          end

        {:map, _} ->
          base_schema = %{"type" => "object"}
          # Check if this map has nested properties defined
          case opts[:properties] do
            properties when is_list(properties) ->
              add_nested_properties(base_schema, properties)

            _ ->
              base_schema
          end

        :keyword_list ->
          %{"type" => "object"}

        :object ->
          base_schema = %{"type" => "object"}

          case opts[:properties] do
            properties when is_list(properties) ->
              add_nested_properties(base_schema, properties)

            _ ->
              base_schema
          end

        :atom ->
          %{"type" => "string"}

        # Fallback to string for unknown types
        _ ->
          %{"type" => "string"}
      end

    # Add description if provided
    case opts[:doc] do
      nil -> base_schema
      doc -> Map.put(base_schema, "description", doc)
    end
  end

  @doc """
  Format a tool into Anthropic tool schema format.

  ## Parameters

    * `tool` - A `ReqLLM.Tool.t()` struct

  ## Returns

  A map containing the Anthropic tool schema format.

  ## Examples

      iex> tool = %ReqLLM.Tool{
      ...>   name: "get_weather",
      ...>   description: "Get current weather",
      ...>   parameter_schema: [
      ...>     location: [type: :string, required: true, doc: "City name"]
      ...>   ],
      ...>   callback: fn _ -> {:ok, %{}} end
      ...> }
      iex> ReqLLM.Schema.to_anthropic_format(tool)
      %{
        "name" => "get_weather",
        "description" => "Get current weather",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["location"]
        }
      }

  """
  @spec to_anthropic_format(ReqLLM.Tool.t()) :: map()
  def to_anthropic_format(%ReqLLM.Tool{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "input_schema" => to_json(tool.parameter_schema)
    }
  end

  @doc """
  Format a tool into OpenAI tool schema format.

  ## Parameters

    * `tool` - A `ReqLLM.Tool.t()` struct

  ## Returns

  A map containing the OpenAI tool schema format.

  ## Examples

      iex> tool = %ReqLLM.Tool{
      ...>   name: "get_weather",
      ...>   description: "Get current weather",
      ...>   parameter_schema: [
      ...>     location: [type: :string, required: true, doc: "City name"]
      ...>   ],
      ...>   callback: fn _ -> {:ok, %{}} end
      ...> }
      iex> ReqLLM.Schema.to_openai_format(tool)
      %{
        "type" => "function",
        "function" => %{
          "name" => "get_weather",
          "description" => "Get current weather",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "location" => %{"type" => "string", "description" => "City name"}
            },
            "required" => ["location"]
          }
        }
      }

  """
  @spec to_openai_format(ReqLLM.Tool.t()) :: map()
  def to_openai_format(%ReqLLM.Tool{} = tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => to_json(tool.parameter_schema)
      }
    }
  end

  @doc """
  Format a tool into Google tool schema format.

  ## Parameters

    * `tool` - A `ReqLLM.Tool.t()` struct

  ## Returns

  A map containing the Google tool schema format.

  ## Examples

      iex> tool = %ReqLLM.Tool{
      ...>   name: "get_weather",
      ...>   description: "Get current weather",
      ...>   parameter_schema: [
      ...>     location: [type: :string, required: true, doc: "City name"]
      ...>   ],
      ...>   callback: fn _ -> {:ok, %{}} end
      ...> }
      iex> ReqLLM.Schema.to_google_format(tool)
      %{
        "name" => "get_weather",
        "description" => "Get current weather",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "location" => %{"type" => "string", "description" => "City name"}
          },
          "required" => ["location"]
        }
      }

  """
  @spec to_google_format(ReqLLM.Tool.t()) :: map()
  def to_google_format(%ReqLLM.Tool{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "parameters" => to_json(tool.parameter_schema)
    }
  end

  @doc """
  Validate data against a keyword schema.

  Takes a data map and validates it against a NimbleOptions-style keyword schema.
  The data is first converted to keyword format for NimbleOptions validation.

  ## Parameters

    * `data` - Map of data to validate
    * `schema` - Keyword schema definition

  ## Returns

    * `{:ok, validated_data}` - Successfully validated data
    * `{:error, error}` - Validation error with details

  ## Examples

      iex> schema = [name: [type: :string, required: true], age: [type: :integer]]
      iex> data = %{"name" => "Alice", "age" => 30}
      iex> ReqLLM.Schema.validate(data, schema)
      {:ok, [name: "Alice", age: 30]}

      iex> schema = [name: [type: :string, required: true]]  
      iex> data = %{"age" => 30}
      iex> ReqLLM.Schema.validate(data, schema)
      {:error, %ReqLLM.Error.Validation.Error{...}}

  """
  @spec validate(map(), keyword()) :: {:ok, keyword()} | {:error, ReqLLM.Error.t()}
  def validate(data, schema) when is_map(data) and is_list(schema) do
    with {:ok, compiled_schema} <- compile(schema) do
      # Convert string keys to atoms for NimbleOptions validation
      keyword_data =
        data
        |> Enum.map(fn {k, v} ->
          key = if is_binary(k), do: String.to_existing_atom(k), else: k
          {key, v}
        end)

      case NimbleOptions.validate(keyword_data, compiled_schema.nimble_schema) do
        {:ok, validated_data} ->
          {:ok, validated_data}

        {:error, %NimbleOptions.ValidationError{} = error} ->
          {:error,
           ReqLLM.Error.Validation.Error.exception(
             tag: :schema_validation_failed,
             reason: Exception.message(error),
             context: [data: data, schema: schema]
           )}
      end
    end
  rescue
    ArgumentError ->
      # Handle the case where string keys don't exist as atoms
      {:error,
       ReqLLM.Error.Validation.Error.exception(
         tag: :invalid_keys,
         reason: "Data contains keys that don't match schema field names",
         context: [data: data, schema: schema]
       )}
  end

  def validate(data, _schema) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "Data must be a map, got: #{inspect(data)}"
     )}
  end
end
