defmodule ReqLLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider implementation using the Provider behavior.

  Supports OpenAI's Chat Completions API and Embeddings API with features including:
  - Text generation with GPT models
  - Streaming responses
  - Tool calling
  - Multi-modal inputs (text and images)
  - Embeddings generation
  - O1/O3 model support with automatic parameter translation

  ## Protocol Usage

  Uses the generic `ReqLLM.Context.Codec` and `ReqLLM.Response.Codec` protocols.
  No custom wrapper modules – leverages the standard OpenAI-compatible codecs.

  ## Configuration

  Set your OpenAI API key via environment variable or JidoKeys:

      # Option 1: Environment variable (automatically loaded)
      OPENAI_API_KEY=sk-...

      # Option 2: Set directly in JidoKeys
      ReqLLM.put_key(:openai_api_key, "sk-...")

  ## Examples

      # Simple text generation
      model = ReqLLM.Model.from("openai:gpt-4")
      {:ok, response} = ReqLLM.generate_text(model, "Hello!")

      # Streaming
      {:ok, stream} = ReqLLM.stream_text(model, "Tell me a story", stream: true)

      # Tool calling
      tools = [%ReqLLM.Tool{name: "get_weather", ...}]
      {:ok, response} = ReqLLM.generate_text(model, "What's the weather?", tools: tools)

      # Embeddings
      {:ok, embedding} = ReqLLM.generate_embedding("openai:text-embedding-3-small", "Hello world")
  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :openai,
    base_url: "https://api.openai.com/v1",
    metadata: "priv/models_dev/openai.json",
    default_env_key: "OPENAI_API_KEY",
    provider_schema: [
      dimensions: [
        type: :pos_integer,
        doc: "Dimensions for embedding models (e.g., text-embedding-3-small supports 512-1536)"
      ],
      encoding_format: [type: :string, doc: "Format for embedding output (float, base64)"]
    ]

  import ReqLLM.Provider.Utils, only: [maybe_put: 3]

  require Logger

  @doc """
  Custom prepare_request for :object operations to maintain OpenAI-specific token handling and O1/O3 model support.
  """
  @impl ReqLLM.Provider

  # All operations delegated to defaults - structured output handled via response_format in encode_body
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @doc """
  Translates provider-specific options for different model types.

  ## O1/O3 Models

  These models have special parameter requirements:
  - `max_tokens` must be renamed to `max_completion_tokens`
  - `temperature` is not supported and will be dropped

  ## Returns

  `{translated_opts, warnings}` where warnings is a list of transformation messages.
  """
  @impl ReqLLM.Provider
  def translate_options(:chat, %ReqLLM.Model{model: <<"o1", _::binary>>}, opts) do
    {opts_after_rename, rename_warnings} =
      translate_rename(opts, :max_tokens, :max_completion_tokens)

    {final_opts, drop_warnings} =
      translate_drop(
        opts_after_rename,
        :temperature,
        "OpenAI o1 models do not support :temperature – dropped"
      )

    {final_opts, rename_warnings ++ drop_warnings}
  end

  def translate_options(:chat, %ReqLLM.Model{model: <<"o3", _::binary>>}, opts) do
    {opts_after_rename, rename_warnings} =
      translate_rename(opts, :max_tokens, :max_completion_tokens)

    {final_opts, drop_warnings} =
      translate_drop(
        opts_after_rename,
        :temperature,
        "OpenAI o3 models do not support :temperature – dropped"
      )

    {final_opts, rename_warnings ++ drop_warnings}
  end

  def translate_options(_operation, _model, opts) do
    {opts, []}
  end

  @doc """
  Custom body encoding that adds OpenAI-specific token handling for O1/O3 models.
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    # Start with default encoding
    request = ReqLLM.Provider.Defaults.default_encode_body(request)

    # Parse the encoded body to add model-specific token handling
    body = Jason.decode!(request.body)

    enhanced_body =
      case request.options[:operation] do
        :embedding ->
          add_embedding_options(body, request.options)

        _ ->
          body_with_tokens = add_token_limits(body, request.options[:model], request.options)
          # Add response_format for structured output if compiled_schema is present
          if request.options[:compiled_schema] do
            add_response_format(body_with_tokens, request.options[:compiled_schema])
          else
            body_with_tokens
          end
      end

    # Re-encode with enhancements
    encoded_body = Jason.encode!(enhanced_body)
    Map.put(request, :body, encoded_body)
  end

  # Helper functions for OpenAI response_format
  defp add_response_format(body, nil), do: body

  defp add_response_format(body, compiled_schema) do
    json_schema = ReqLLM.Schema.to_json(compiled_schema.schema)
    openai_schema = convert_to_openai_schema(json_schema)

    response_format = %{
      type: "json_schema",
      json_schema: %{
        name: "structured_output",
        strict: true,
        schema: openai_schema
      }
    }

    Map.put(body, :response_format, response_format)
  end

  defp convert_to_openai_schema(%{"type" => "object"} = schema) do
    schema
    |> Map.put("additionalProperties", false)
    |> then(fn s ->
      case s do
        %{"properties" => properties} when is_map(properties) ->
          converted_properties =
            Map.new(properties, fn {k, v} ->
              {k, convert_to_openai_schema(v)}
            end)

          Map.put(s, "properties", converted_properties)

        _ ->
          s
      end
    end)
  end

  defp convert_to_openai_schema(%{"type" => "array", "items" => items} = schema)
       when is_map(items) do
    Map.put(schema, "items", convert_to_openai_schema(items))
  end

  defp convert_to_openai_schema(schema), do: schema

  defp add_embedding_options(body, request_options) do
    provider_opts = request_options[:provider_options] || []

    body
    |> maybe_put(:dimensions, provider_opts[:dimensions])
    |> maybe_put(:encoding_format, provider_opts[:encoding_format])
  end

  @doc """
  Custom decode_response to ensure proper "OpenAI API error" naming.
  """
  @impl ReqLLM.Provider
  def decode_response({req, resp}) do
    case resp.status do
      200 ->
        ReqLLM.Provider.Defaults.default_decode_response({req, resp})

      status ->
        decode_openai_error_response(req, resp, status)
    end
  end

  defp decode_openai_error_response(req, resp, status) do
    err =
      ReqLLM.Error.API.Response.exception(
        reason: "OpenAI API error",
        status: status,
        response_body: resp.body
      )

    {req, err}
  end

  @doc false
  defp add_token_limits(body, model_name, request_options) do
    case model_name do
      <<"o1", _::binary>> ->
        maybe_put(body, :max_completion_tokens, request_options[:max_completion_tokens])

      <<"o3", _::binary>> ->
        maybe_put(body, :max_completion_tokens, request_options[:max_completion_tokens])

      _ ->
        maybe_put(body, :max_tokens, request_options[:max_tokens])
    end
  end
end
