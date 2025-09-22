defmodule ReqLLM.SchemaTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Schema
  alias ReqLLM.Tool

  describe "compile/1" do
    test "compiles valid keyword schemas" do
      schema = [name: [type: :string, required: true], age: [type: :pos_integer, default: 0]]
      assert {:ok, compiled} = Schema.compile(schema)
      assert %{schema: ^schema, nimble_schema: %NimbleOptions{}} = compiled
    end

    test "compiles empty schema" do
      assert {:ok, compiled} = Schema.compile([])
      assert %{schema: [], nimble_schema: %NimbleOptions{}} = compiled
    end

    test "returns error for invalid input types" do
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.compile("invalid")
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.compile(%{})
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.compile(123)
    end

    test "returns error for malformed schema" do
      assert {:error, %ReqLLM.Error.Validation.Error{}} = Schema.compile([:invalid])
      assert {:error, %ReqLLM.Error.Validation.Error{}} = Schema.compile(name: :invalid)
    end
  end

  describe "to_json/1" do
    test "converts empty schema" do
      assert Schema.to_json([]) == %{"type" => "object", "properties" => %{}}
    end

    test "converts simple schema with required fields" do
      schema = [name: [type: :string, required: true, doc: "User name"]]

      result = Schema.to_json(schema)

      assert result["type"] == "object"
      assert result["properties"]["name"] == %{"type" => "string", "description" => "User name"}
      assert result["required"] == ["name"]
    end

    test "converts complex schema" do
      schema = [
        name: [type: :string, required: true, doc: "User name"],
        age: [type: :pos_integer, doc: "User age"],
        tags: [type: {:list, :string}, doc: "User tags"],
        active: [type: :boolean, required: true]
      ]

      result = Schema.to_json(schema)

      assert result["type"] == "object"
      assert result["properties"]["name"]["type"] == "string"
      assert result["properties"]["age"]["type"] == "integer"
      assert result["properties"]["age"]["minimum"] == 1
      assert result["properties"]["tags"]["type"] == "array"
      assert result["properties"]["tags"]["items"]["type"] == "string"
      assert result["properties"]["active"]["type"] == "boolean"
      assert Enum.sort(result["required"]) == ["active", "name"]
    end

    test "handles schema without required fields" do
      schema = [name: [type: :string, doc: "User name"], age: [type: :integer]]

      result = Schema.to_json(schema)

      refute Map.has_key?(result, "required")
    end

    test "reverses field order for required fields" do
      schema = [
        c: [type: :string, required: true],
        a: [type: :string, required: true],
        b: [type: :string, required: true]
      ]

      result = Schema.to_json(schema)

      assert result["required"] == ["c", "a", "b"]
    end
  end

  describe "nimble_type_to_json_schema/2" do
    test "converts basic types" do
      assert Schema.nimble_type_to_json_schema(:string, []) == %{"type" => "string"}
      assert Schema.nimble_type_to_json_schema(:integer, []) == %{"type" => "integer"}
      assert Schema.nimble_type_to_json_schema(:boolean, []) == %{"type" => "boolean"}
      assert Schema.nimble_type_to_json_schema(:float, []) == %{"type" => "number"}
      assert Schema.nimble_type_to_json_schema(:number, []) == %{"type" => "number"}
      assert Schema.nimble_type_to_json_schema(:map, []) == %{"type" => "object"}
      assert Schema.nimble_type_to_json_schema(:atom, []) == %{"type" => "string"}
    end

    test "converts constrained types" do
      assert Schema.nimble_type_to_json_schema(:pos_integer, []) == %{
               "type" => "integer",
               "minimum" => 1
             }
    end

    test "converts list types" do
      assert Schema.nimble_type_to_json_schema({:list, :string}, []) == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :integer}, []) == %{
               "type" => "array",
               "items" => %{"type" => "integer"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :boolean}, []) == %{
               "type" => "array",
               "items" => %{"type" => "boolean"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :float}, []) == %{
               "type" => "array",
               "items" => %{"type" => "number"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :number}, []) == %{
               "type" => "array",
               "items" => %{"type" => "number"}
             }

      assert Schema.nimble_type_to_json_schema({:list, :pos_integer}, []) == %{
               "type" => "array",
               "items" => %{"type" => "integer", "minimum" => 1}
             }
    end

    test "converts nested list types recursively" do
      assert Schema.nimble_type_to_json_schema({:list, :atom}, []) == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "converts map types" do
      assert Schema.nimble_type_to_json_schema({:map, :any}, []) == %{"type" => "object"}
      assert Schema.nimble_type_to_json_schema(:keyword_list, []) == %{"type" => "object"}
    end

    test "fallback for unknown types" do
      assert Schema.nimble_type_to_json_schema(:custom_type, []) == %{"type" => "string"}
      assert Schema.nimble_type_to_json_schema({:custom, :type}, []) == %{"type" => "string"}
    end

    test "adds description from doc option" do
      result = Schema.nimble_type_to_json_schema(:string, doc: "A text field")
      assert result == %{"type" => "string", "description" => "A text field"}

      result = Schema.nimble_type_to_json_schema({:list, :string}, doc: "List of strings")

      assert result == %{
               "type" => "array",
               "items" => %{"type" => "string"},
               "description" => "List of strings"
             }
    end

    test "ignores nil doc option" do
      result = Schema.nimble_type_to_json_schema(:string, doc: nil)
      assert result == %{"type" => "string"}

      result = Schema.nimble_type_to_json_schema(:string, [])
      assert result == %{"type" => "string"}
    end
  end

  describe "to_anthropic_format/1" do
    setup do
      tool = %Tool{
        name: "search",
        description: "Search for items",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query"],
          limit: [type: :pos_integer, doc: "Maximum results"]
        ],
        callback: fn _ -> {:ok, %{}} end
      }

      {:ok, tool: tool}
    end

    test "formats tool with parameters", %{tool: tool} do
      result = Schema.to_anthropic_format(tool)

      assert result == %{
               "name" => "search",
               "description" => "Search for items",
               "input_schema" => %{
                 "type" => "object",
                 "properties" => %{
                   "query" => %{"type" => "string", "description" => "Search query"},
                   "limit" => %{
                     "type" => "integer",
                     "minimum" => 1,
                     "description" => "Maximum results"
                   }
                 },
                 "required" => ["query"]
               }
             }
    end

    test "formats tool without parameters" do
      tool = %Tool{
        name: "ping",
        description: "Health check",
        parameter_schema: [],
        callback: fn _ -> {:ok, %{}} end
      }

      result = Schema.to_anthropic_format(tool)

      assert result == %{
               "name" => "ping",
               "description" => "Health check",
               "input_schema" => %{
                 "type" => "object",
                 "properties" => %{}
               }
             }
    end

    test "formats tool with complex parameter types" do
      tool = %Tool{
        name: "complex_tool",
        description: "Tool with various parameter types",
        parameter_schema: [
          tags: [type: {:list, :string}, required: true, doc: "List of tags"],
          enabled: [type: :boolean, doc: "Whether enabled"],
          config: [type: :map, doc: "Configuration object"]
        ],
        callback: fn _ -> {:ok, %{}} end
      }

      result = Schema.to_anthropic_format(tool)

      assert result["input_schema"]["properties"]["tags"]["type"] == "array"
      assert result["input_schema"]["properties"]["tags"]["items"]["type"] == "string"
      assert result["input_schema"]["properties"]["enabled"]["type"] == "boolean"
      assert result["input_schema"]["properties"]["config"]["type"] == "object"
      assert result["input_schema"]["required"] == ["tags"]
    end
  end

  # Consolidated tool format tests using table-driven approach
  describe "tool formatting" do
    setup do
      basic_tool = %Tool{
        name: "search",
        description: "Search for items",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query"],
          limit: [type: :pos_integer, doc: "Maximum results"]
        ],
        callback: fn _ -> {:ok, %{}} end
      }

      empty_tool = %Tool{
        name: "ping",
        description: "Health check",
        parameter_schema: [],
        callback: fn _ -> {:ok, %{}} end
      }

      complex_tool = %Tool{
        name: "complex_tool",
        description: "Tool with various parameter types",
        parameter_schema: [
          tags: [type: {:list, :string}, required: true, doc: "List of tags"],
          enabled: [type: :boolean, doc: "Whether enabled"],
          config: [type: :map, doc: "Configuration object"]
        ],
        callback: fn _ -> {:ok, %{}} end
      }

      {:ok, basic_tool: basic_tool, empty_tool: empty_tool, complex_tool: complex_tool}
    end

    test "to_openai_format/1", %{
      basic_tool: tool,
      empty_tool: empty_tool,
      complex_tool: complex_tool
    } do
      # Test with parameters
      result = Schema.to_openai_format(tool)
      assert result["type"] == "function"
      assert result["function"]["name"] == "search"
      assert result["function"]["parameters"]["required"] == ["query"]

      # Test without parameters
      result = Schema.to_openai_format(empty_tool)
      assert result["function"]["parameters"]["properties"] == %{}
      refute Map.has_key?(result["function"]["parameters"], "required")

      # Test complex types
      result = Schema.to_openai_format(complex_tool)
      assert result["function"]["parameters"]["properties"]["tags"]["type"] == "array"
      assert result["function"]["parameters"]["properties"]["config"]["type"] == "object"
    end

    test "to_google_format/1", %{
      basic_tool: tool,
      empty_tool: empty_tool,
      complex_tool: complex_tool
    } do
      # Test with parameters
      result = Schema.to_google_format(tool)

      assert result == %{
               "name" => "search",
               "description" => "Search for items",
               "parameters" => %{
                 "type" => "object",
                 "properties" => %{
                   "query" => %{"type" => "string", "description" => "Search query"},
                   "limit" => %{
                     "type" => "integer",
                     "minimum" => 1,
                     "description" => "Maximum results"
                   }
                 },
                 "required" => ["query"]
               }
             }

      # Test without parameters
      result = Schema.to_google_format(empty_tool)

      assert result == %{
               "name" => "ping",
               "description" => "Health check",
               "parameters" => %{"type" => "object", "properties" => %{}}
             }

      # Test complex types
      result = Schema.to_google_format(complex_tool)
      assert result["parameters"]["properties"]["tags"]["type"] == "array"
      assert result["parameters"]["properties"]["enabled"]["type"] == "boolean"
      assert result["parameters"]["required"] == ["tags"]
    end

    test "format consistency across providers", %{basic_tool: tool} do
      anthropic = Schema.to_anthropic_format(tool)
      openai = Schema.to_openai_format(tool)
      google = Schema.to_google_format(tool)

      # All should have same core schema structure
      anthropic_schema = anthropic["input_schema"]
      openai_schema = openai["function"]["parameters"]
      google_schema = google["parameters"]

      assert anthropic_schema == openai_schema
      assert openai_schema == google_schema
    end
  end

  describe "nested list/map conversion scenarios" do
    test "converts nested list of maps" do
      schema = [
        users: [
          type: {:list, :map},
          doc: "List of user objects",
          properties: [
            name: [type: :string, required: true],
            email: [type: :string, required: true]
          ]
        ]
      ]

      result = Schema.to_json(schema)

      assert result["properties"]["users"]["type"] == "array"
      assert result["properties"]["users"]["items"]["type"] == "object"
    end

    test "converts deeply nested structures" do
      schema = [
        matrix: [type: {:list, {:list, :integer}}, doc: "2D array"],
        nested_maps: [type: {:list, {:map, :string}}, doc: "List of string maps"],
        custom_nested: [type: {:list, :atom}, doc: "List of atoms (fallback to string)"]
      ]

      result = Schema.to_json(schema)

      # Test nested lists
      matrix_prop = result["properties"]["matrix"]
      assert matrix_prop["type"] == "array"
      assert matrix_prop["items"]["type"] == "array"
      assert matrix_prop["items"]["items"]["type"] == "integer"

      # Test nested map types
      nested_maps_prop = result["properties"]["nested_maps"]
      assert nested_maps_prop["type"] == "array"
      assert nested_maps_prop["items"]["type"] == "object"

      # Test fallback in nested context
      custom_prop = result["properties"]["custom_nested"]
      assert custom_prop["type"] == "array"
      assert custom_prop["items"]["type"] == "string"
    end

    test "handles mixed complex types" do
      schema = [
        data: [
          type: :map,
          doc: "Complex data structure",
          properties: [
            tags: [type: {:list, :string}],
            metadata: [type: {:map, :any}],
            scores: [type: {:list, :float}]
          ]
        ]
      ]

      result = Schema.to_json(schema)
      data_prop = result["properties"]["data"]

      assert data_prop["type"] == "object"
      assert data_prop["description"] == "Complex data structure"
    end
  end

  describe "validate/2" do
    test "validates data against simple schema" do
      schema = [name: [type: :string, required: true], age: [type: :integer]]
      data = %{"name" => "Alice", "age" => 30}

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated[:name] == "Alice"
      assert validated[:age] == 30
    end

    test "validates data with atom keys" do
      schema = [name: [type: :string, required: true]]
      data = %{name: "Bob"}

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated[:name] == "Bob"
    end

    test "returns error for missing required field" do
      schema = [name: [type: :string, required: true], age: [type: :integer]]
      data = %{"age" => 30}

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :schema_validation_failed}} =
               Schema.validate(data, schema)
    end

    test "returns error for invalid field type" do
      schema = [age: [type: :integer, required: true]]
      data = %{"age" => "not_an_integer"}

      assert {:error, %ReqLLM.Error.Validation.Error{}} = Schema.validate(data, schema)
    end

    test "handles string keys that don't exist as atoms" do
      schema = [existing_field: [type: :string]]
      data = %{"non_existing_field" => "value"}

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :invalid_keys}} =
               Schema.validate(data, schema)
    end

    test "returns error for non-map data" do
      schema = [name: [type: :string]]

      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.validate("not_a_map", schema)
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.validate([], schema)
      assert {:error, %ReqLLM.Error.Invalid.Parameter{}} = Schema.validate(123, schema)
    end

    test "validates complex nested data" do
      schema = [
        user: [type: :string, required: true],
        preferences: [type: :map],
        tags: [type: {:list, :string}]
      ]

      data = %{
        "user" => "alice",
        "preferences" => %{theme: "dark"},
        "tags" => ["admin", "beta"]
      }

      assert {:ok, validated} = Schema.validate(data, schema)
      assert validated[:user] == "alice"
      assert validated[:preferences] == %{theme: "dark"}
      assert validated[:tags] == ["admin", "beta"]
    end

    test "validates empty data and schema" do
      assert {:ok, []} = Schema.validate(%{}, [])
    end

    test "handles validation with malformed schema" do
      schema = [:invalid_schema_format]
      data = %{"name" => "Alice"}

      assert {:error, %ReqLLM.Error.Validation.Error{tag: :invalid_schema}} =
               Schema.validate(data, schema)
    end
  end
end
