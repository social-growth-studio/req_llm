defmodule ReqLLM.Tool do
  @moduledoc """
  Tool definition for AI model function calling.

  Tools enable AI models to call external functions, perform actions, and retrieve information.
  Each tool has a name, description, parameters schema, and a callback function to execute.

  ## Basic Usage

      # Create a simple tool
      {:ok, tool} = ReqLLM.Tool.new(
        name: "get_weather",
        description: "Get current weather for a location",
        parameter_schema: [
          location: [type: :string, required: true, doc: "City name"]
        ],
        callback: {WeatherService, :get_current_weather}
      )

      # Execute the tool
      {:ok, result} = ReqLLM.Tool.execute(tool, %{location: "San Francisco"})

      # Get provider-specific schema
      anthropic_schema = ReqLLM.Tool.to_schema(tool, :anthropic)

  ## Parameters Schema

  Parameters are defined using NimbleOptions-compatible keyword lists:

      parameter_schema: [
        location: [type: :string, required: true, doc: "City name"],
        units: [type: :string, default: "celsius", doc: "Temperature units"]
      ]

  ## Callback Formats

  Multiple callback formats are supported:

      # Module and function (args passed as single argument)
      callback: {MyModule, :my_function}

      # Module, function, and additional args (prepended to input)
      callback: {MyModule, :my_function, [:extra, :args]}

      # Anonymous function
      callback: fn args -> {:ok, "result"} end

  ## Provider Schema Formats

  Tools can be converted to provider-specific formats:

      # Anthropic tool format
      anthropic_schema = ReqLLM.Tool.to_schema(tool, :anthropic)

  ## Functions

    * `new/1` - Creates a new Tool from the given options
    * `new!/1` - Creates a new Tool from the given options, raising on error
    * `execute/2` - Executes a tool with the given input parameters
    * `to_schema/2` - Converts a Tool to provider-specific schema format
    * `to_json_schema/1` - Converts a Tool to JSON Schema format for LLM integration
    * `valid_name?/1` - Validates a tool name for compliance with function calling standards

  """

  use TypedStruct

  @type callback_mfa :: {module(), atom()} | {module(), atom(), list()}
  @type callback_fun :: (map() -> {:ok, term()} | {:error, term()})
  @type callback :: callback_mfa() | callback_fun()

  typedstruct enforce: true do
    @typedoc "A tool definition for AI model function calling"

    field(:name, String.t(), enforce: true)
    field(:description, String.t(), enforce: true)
    field(:parameter_schema, keyword(), default: [])
    field(:compiled, term() | nil, default: nil)
    field(:callback, callback(), enforce: true)
  end

  @type tool_opts :: [
          name: String.t(),
          description: String.t(),
          parameter_schema: keyword(),
          callback: callback()
        ]

  # NimbleOptions schema for tool creation validation
  @tool_schema NimbleOptions.new!(
                 name: [
                   type: :string,
                   required: true,
                   doc: "Tool name (must be valid identifier)"
                 ],
                 description: [
                   type: :string,
                   required: true,
                   doc: "Tool description for AI model"
                 ],
                 parameter_schema: [
                   type: :keyword_list,
                   default: [],
                   doc: "Parameter schema as keyword list"
                 ],
                 callback: [
                   type: :any,
                   required: true,
                   doc: "Callback function or MFA tuple"
                 ]
               )

  @doc """
  Creates a new Tool from the given options.

  ## Parameters

    * `opts` - Tool options as keyword list

  ## Options

    * `:name` - Tool name (required, must be valid identifier)
    * `:description` - Tool description for AI model (required)
    * `:parameter_schema` - Parameter schema as NimbleOptions keyword list (optional)
    * `:callback` - Callback function or MFA tuple (required)

  ## Examples

      {:ok, tool} = ReqLLM.Tool.new(
        name: "get_weather",
        description: "Get current weather",
        parameter_schema: [
          location: [type: :string, required: true]
        ],
        callback: {WeatherService, :get_weather}
      )

  """
  @spec new(tool_opts()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, validated_opts} <- NimbleOptions.validate(opts, @tool_schema),
         :ok <- validate_name(validated_opts[:name]),
         :ok <- validate_callback(validated_opts[:callback]),
         {:ok, compiled_schema} <- compile_parameter_schema(validated_opts[:parameter_schema]) do
      tool = %__MODULE__{
        name: validated_opts[:name],
        description: validated_opts[:description],
        parameter_schema: validated_opts[:parameter_schema],
        compiled: compiled_schema,
        callback: validated_opts[:callback]
      }

      {:ok, tool}
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        {:error,
         ReqLLM.Error.Validation.Error.exception(
           tag: :invalid_options,
           reason: Exception.message(error),
           context: []
         )}

      {:error, reason} when is_binary(reason) ->
        {:error, ReqLLM.Error.Invalid.Parameter.exception(parameter: reason)}

      error ->
        error
    end
  end

  def new(_) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(parameter: "Tool options must be a keyword list")}
  end

  @doc """
  Creates a new Tool from the given options, raising on error.

  See `new/1` for details.

  ## Examples

      tool = ReqLLM.Tool.new!(
        name: "get_weather",
        description: "Get current weather",
        callback: {WeatherService, :get_weather}
      )

  """
  @spec new!(tool_opts()) :: t() | no_return()
  def new!(opts) do
    case new(opts) do
      {:ok, tool} -> tool
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes a tool with the given input parameters.

  Validates input parameters against the tool's schema and calls the callback function.
  The callback is expected to return `{:ok, result}` or `{:error, reason}`.

  ## Parameters

    * `tool` - Tool struct
    * `input` - Input parameters as map

  ## Examples

      {:ok, result} = ReqLLM.Tool.execute(tool, %{location: "San Francisco"})
      #=> {:ok, %{temperature: 72, conditions: "sunny"}}

      {:error, reason} = ReqLLM.Tool.execute(tool, %{invalid: "params"})
      #=> {:error, %ReqLLM.Error.Validation.Error{...}}

  """
  @spec execute(t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{} = tool, input) when is_map(input) do
    with {:ok, validated_input} <- validate_input(tool, input) do
      call_callback(tool.callback, validated_input)
    end
  end

  def execute(%__MODULE__{}, input) do
    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter: "Input must be a map, got: #{inspect(input)}"
     )}
  end

  @doc """
  Converts a Tool to provider-specific schema format.

  Returns a map containing the provider's expected tool format with
  tool name, description, and parameter definitions.

  ## Parameters

    * `tool` - Tool struct
    * `provider` - Provider atom (`:anthropic`)

  ## Examples

      # Anthropic tool format
      anthropic_schema = ReqLLM.Tool.to_schema(tool, :anthropic)
      #=> %{
      #     "name" => "get_weather",
      #     "description" => "Get current weather",
      #     "input_schema" => %{...}
      #   }

  """
  @spec to_schema(t(), atom()) :: map()
  def to_schema(%__MODULE__{} = tool, provider \\ :openai) do
    case provider do
      :anthropic -> ReqLLM.Schema.to_anthropic_format(tool)
      :openai -> ReqLLM.Schema.to_openai_format(tool)
      :google -> ReqLLM.Schema.to_google_format(tool)
      other -> raise ArgumentError, "Unknown provider #{inspect(other)}"
    end
  end

  @doc """
  Converts a Tool to JSON Schema format for LLM integration.

  Backward compatibility function that defaults to OpenAI format.
  Use `to_schema/2` for explicit provider selection.

  ## Examples

      json_schema = ReqLLM.Tool.to_json_schema(tool)
      # Equivalent to: ReqLLM.Tool.to_schema(tool, :openai)

  """
  @spec to_json_schema(t()) :: map()
  def to_json_schema(%__MODULE__{} = tool) do
    to_schema(tool, :openai)
  end

  @doc """
  Validates a tool name for compliance with function calling standards.

  Tool names must be valid identifiers (alphanumeric + underscores, start with letter/underscore).

  ## Examples

      ReqLLM.Tool.valid_name?("get_weather")
      #=> true

      ReqLLM.Tool.valid_name?("123invalid")
      #=> false

  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name) do
    Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, name) and String.length(name) <= 64
  end

  def valid_name?(_), do: false

  # Private functions

  defp validate_name(name) do
    if valid_name?(name) do
      :ok
    else
      {:error,
       "Invalid tool name: #{inspect(name)}. Must be valid identifier (alphanumeric + underscore, max 64 chars)"}
    end
  end

  defp validate_callback({module, function}) when is_atom(module) and is_atom(function) do
    if function_exported?(module, function, 1) do
      :ok
    else
      {:error, "Callback function #{module}.#{function}/1 does not exist"}
    end
  end

  defp validate_callback({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    arity = length(args) + 1

    if function_exported?(module, function, arity) do
      :ok
    else
      {:error, "Callback function #{module}.#{function}/#{arity} does not exist"}
    end
  end

  defp validate_callback(fun) when is_function(fun, 1), do: :ok

  defp validate_callback(callback) do
    {:error,
     "Invalid callback: #{inspect(callback)}. Must be {module, function}, {module, function, args}, or function/1"}
  end

  defp compile_parameter_schema([]), do: {:ok, nil}

  defp compile_parameter_schema(parameter_schema) when is_list(parameter_schema) do
    ReqLLM.Schema.compile(parameter_schema)
  end

  defp validate_input(%__MODULE__{compiled: nil}, input), do: {:ok, input}

  defp validate_input(%__MODULE__{compiled: schema}, input) do
    normalized_input = normalize_input_keys(input)

    case NimbleOptions.validate(normalized_input, schema.nimble_schema) do
      {:ok, validated_input} ->
        {:ok, validated_input}

      {:error, error} ->
        {:error,
         ReqLLM.Error.Validation.Error.exception(
           tag: :parameter_validation,
           reason: Exception.message(error),
           context: [input: input]
         )}
    end
  end

  defp normalize_input_keys(input) when is_map(input) do
    Map.new(input, fn
      {key, value} when is_binary(key) ->
        try do
          {String.to_existing_atom(key), value}
        rescue
          ArgumentError -> {String.to_atom(key), value}
        end

      {key, value} ->
        {key, value}
    end)
  end

  defp call_callback({module, function}, input) do
    apply(module, function, [input])
  rescue
    error ->
      {:error,
       ReqLLM.Error.Unknown.Unknown.exception(
         error: "Callback execution failed: #{Exception.message(error)}"
       )}
  end

  defp call_callback({module, function, args}, input) do
    apply(module, function, args ++ [input])
  rescue
    error ->
      {:error,
       ReqLLM.Error.Unknown.Unknown.exception(
         error: "Callback execution failed: #{Exception.message(error)}"
       )}
  end

  defp call_callback(fun, input) when is_function(fun, 1) do
    fun.(input)
  rescue
    error ->
      {:error,
       ReqLLM.Error.Unknown.Unknown.exception(
         error: "Callback execution failed: #{Exception.message(error)}"
       )}
  end

  defimpl Inspect do
    def inspect(%{name: name, parameter_schema: schema}, opts) do
      param_count = length(schema)
      param_desc = if param_count == 0, do: "no params", else: "#{param_count} params"

      Inspect.Algebra.concat([
        "#Tool<",
        Inspect.Algebra.to_doc(name, opts),
        " ",
        param_desc,
        ">"
      ])
    end
  end
end
