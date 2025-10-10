defmodule ReqLLM.Providers.Anthropic do
  @moduledoc """
  Provider implementation for Anthropic Claude models.

  Supports Claude 3 models including:
  - claude-3-5-sonnet-20241022
  - claude-3-5-haiku-20241022
  - claude-3-opus-20240229

  ## Key Differences from OpenAI

  - Uses `/v1/messages` endpoint instead of `/chat/completions`
  - Different authentication: `x-api-key` header instead of `Authorization: Bearer`
  - Different message format with content blocks
  - Different response structure with top-level `role` and `content`
  - System messages are included in the messages array, not separate
  - Tool calls use different format with content blocks

  ## Usage

      iex> ReqLLM.generate_text("anthropic:claude-3-5-sonnet-20241022", "Hello!")
      {:ok, response}

  """

  @behaviour ReqLLM.Provider

  use ReqLLM.Provider.DSL,
    id: :anthropic,
    base_url: "https://api.anthropic.com",
    metadata: "priv/models_dev/anthropic.json",
    default_env_key: "ANTHROPIC_API_KEY",
    provider_schema: [
      anthropic_top_k: [
        type: :pos_integer,
        doc: "Sample from the top K options for each subsequent token (1-40)"
      ],
      anthropic_version: [
        type: :string,
        doc: "Anthropic API version to use",
        default: "2023-06-01"
      ],
      stop_sequences: [
        type: {:list, :string},
        doc: "Custom sequences that will cause the model to stop generating"
      ],
      anthropic_metadata: [
        type: :map,
        doc: "Optional metadata to include with the request"
      ],
      thinking: [
        type: :map,
        doc:
          "Enable thinking/reasoning for supported models (e.g. %{type: \"enabled\", budget_tokens: 4096})"
      ]
    ]

  import ReqLLM.Provider.Utils, only: [maybe_put: 3, ensure_parsed_body: 1]

  require Logger

  @extra_option_keys ~w(
    model compiled_schema temperature max_tokens app_referer app_title fixture
  )a

  @req_keys ~w(
    context operation text stream model provider_options
  )a

  @body_options ~w(
    temperature top_p stop_sequences thinking
  )a

  @unsupported_parameters ~w(
    presence_penalty frequency_penalty logprobs top_logprobs response_format
  )a

  @default_anthropic_version "2023-06-01"
  @anthropic_beta_tools "tools-2024-05-16"

  @impl ReqLLM.Provider
  def prepare_request(:chat, model_spec, prompt, opts) do
    with {:ok, model} <- ReqLLM.Model.from(model_spec),
         {:ok, context} <- ReqLLM.Context.normalize(prompt, opts),
         opts_with_context = Keyword.put(opts, :context, context),
         {:ok, processed_opts} <-
           ReqLLM.Provider.Options.process(__MODULE__, :chat, model, opts_with_context) do
      http_opts = Keyword.get(processed_opts, :req_http_options, [])

      req_keys = supported_provider_options() ++ @req_keys

      default_timeout =
        if Keyword.has_key?(processed_opts, :thinking) do
          Application.get_env(:req_llm, :thinking_timeout, 300_000)
        else
          Application.get_env(:req_llm, :receive_timeout, 120_000)
        end

      timeout = Keyword.get(processed_opts, :receive_timeout, default_timeout)

      request =
        Req.new(
          [
            url: "/v1/messages",
            method: :post,
            receive_timeout: timeout,
            pool_timeout: timeout,
            connect_options: [timeout: timeout]
          ] ++ http_opts
        )
        |> Req.Request.register_options(req_keys)
        |> Req.Request.merge_options(
          Keyword.take(processed_opts, req_keys) ++
            [
              model: model.model,
              base_url: Keyword.get(processed_opts, :base_url, default_base_url())
            ]
        )
        |> attach(model, processed_opts)

      {:ok, request}
    end
  end

  @impl ReqLLM.Provider
  def prepare_request(:object, model_spec, prompt, opts) do
    compiled_schema = Keyword.fetch!(opts, :compiled_schema)

    structured_output_tool =
      ReqLLM.Tool.new!(
        name: "structured_output",
        description: "Generate structured output matching the provided schema",
        parameter_schema: compiled_schema.schema,
        callback: fn _args -> {:ok, "structured output generated"} end
      )

    opts_with_tool =
      opts
      |> Keyword.update(:tools, [structured_output_tool], &[structured_output_tool | &1])
      |> Keyword.put(:tool_choice, %{type: "tool", name: "structured_output"})
      |> Keyword.put_new(:max_tokens, 4096)
      |> Keyword.put(:operation, :object)

    prepare_request(:chat, model_spec, prompt, opts_with_tool)
  end

  @impl ReqLLM.Provider
  def prepare_request(operation, _model_spec, _input, _opts) do
    supported_operations = [:chat, :object]

    {:error,
     ReqLLM.Error.Invalid.Parameter.exception(
       parameter:
         "operation: #{inspect(operation)} not supported by #{inspect(__MODULE__)}. Supported operations: #{inspect(supported_operations)}"
     )}
  end

  @impl ReqLLM.Provider
  def attach(request, model, user_opts) do
    # Validate provider compatibility
    if model.provider != :anthropic do
      raise ReqLLM.Error.Invalid.Provider.exception(provider: model.provider)
    end

    api_key = ReqLLM.Keys.get!(model, user_opts)

    # Register options that might be passed by users but aren't standard Req options
    extra_option_keys = @extra_option_keys ++ supported_provider_options()

    request
    |> Req.Request.register_options(extra_option_keys ++ [:anthropic_version, :anthropic_beta])
    |> Req.Request.put_header("content-type", "application/json")
    |> Req.Request.put_header("x-api-key", api_key)
    |> Req.Request.put_header("anthropic-version", get_anthropic_version(user_opts))
    |> Req.Request.put_private(:req_llm_model, model)
    |> maybe_add_beta_header(user_opts)
    |> Req.Request.merge_options([model: model.model] ++ user_opts)
    |> ReqLLM.Step.Error.attach()
    |> Req.Request.append_request_steps(llm_encode_body: &encode_body/1)
    |> Req.Request.append_response_steps(llm_decode_response: &decode_response/1)
    |> ReqLLM.Step.Usage.attach(model)
    |> ReqLLM.Step.Fixture.maybe_attach(model, user_opts)
    |> Req.Request.put_private(:req_llm_model, model)
  end

  @impl ReqLLM.Provider
  def encode_body(request) do
    context = request.options[:context]
    model_name = request.options[:model]
    opts = request.options

    body = build_request_body(context, model_name, opts)
    json_body = Jason.encode!(body)

    %{request | body: json_body}
  end

  @impl ReqLLM.Provider
  def decode_response({request, response}) do
    case response.status do
      status when status in 200..299 ->
        decode_success_response(request, response)

      status ->
        decode_error_response(request, response, status)
    end
  end

  @impl ReqLLM.Provider
  def extract_usage(body, _model) when is_map(body) do
    case body do
      %{"usage" => usage} -> {:ok, usage}
      _ -> {:error, :no_usage_found}
    end
  end

  def extract_usage(_, _), do: {:error, :invalid_body}

  # ========================================================================
  # Shared Request Building Helpers (used by both Req and Finch paths)
  # ========================================================================

  defp build_request_headers(model, opts) do
    api_key = ReqLLM.Keys.get!(model, opts)

    [
      {"content-type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", get_anthropic_version(opts)}
    ]
  end

  defp build_request_body(context, model_name, opts) do
    # Use Anthropic-specific context encoding
    body_data = ReqLLM.Providers.Anthropic.Context.encode_request(context, %{model: model_name})

    # Ensure max_tokens is always present (required by Anthropic)
    max_tokens =
      case get_option(opts, :max_tokens) do
        nil -> default_max_tokens(model_name)
        v -> v
      end

    body_data
    |> add_basic_options(opts)
    |> maybe_put(:stream, get_option(opts, :stream))
    |> Map.put(:max_tokens, max_tokens)
    |> maybe_add_tools(opts)
  end

  defp build_request_url(opts) do
    base_url = get_option(opts, :base_url, default_base_url())
    "#{base_url}/v1/messages"
  end

  defp build_beta_headers(opts) do
    beta_features = []

    beta_features =
      if has_tools?(opts) do
        [@anthropic_beta_tools | beta_features]
      else
        beta_features
      end

    beta_features =
      if has_thinking?(opts) do
        ["interleaved-thinking-2025-05-14" | beta_features]
      else
        beta_features
      end

    case beta_features do
      [] -> []
      features -> [{"anthropic-beta", Enum.join(features, ",")}]
    end
  end

  # ========================================================================

  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    # Extract and merge provider_options for translation
    {provider_options, standard_opts} = Keyword.pop(opts, :provider_options, [])
    flattened_opts = Keyword.merge(standard_opts, provider_options)

    # Translate provider options (including reasoning_effort) before building body
    {translated_opts, _warnings} = translate_options(:chat, model, flattened_opts)

    # Set default timeout for reasoning models
    default_timeout =
      if Keyword.has_key?(translated_opts, :thinking) do
        Application.get_env(:req_llm, :thinking_timeout, 300_000)
      else
        Application.get_env(:req_llm, :receive_timeout, 120_000)
      end

    translated_opts = Keyword.put_new(translated_opts, :receive_timeout, default_timeout)

    # Build request using shared helpers
    headers = build_request_headers(model, translated_opts)
    streaming_headers = [{"Accept", "text/event-stream"} | headers]
    beta_headers = build_beta_headers(translated_opts)
    all_headers = streaming_headers ++ beta_headers

    body = build_request_body(context, model.model, translated_opts ++ [stream: true])
    url = build_request_url(translated_opts)

    finch_request = Finch.build(:post, url, all_headers, Jason.encode!(body))
    {:ok, finch_request}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Anthropic stream request: #{inspect(error)}"
       )}
  end

  @impl ReqLLM.Provider
  def decode_sse_event(event, model) do
    ReqLLM.Providers.Anthropic.Response.decode_sse_event(event, model)
  end

  @impl ReqLLM.Provider
  def translate_options(operation, _model, opts) do
    # Anthropic-specific parameter translation
    translated_opts =
      opts
      |> translate_stop_parameter()
      |> translate_reasoning_effort()
      |> disable_thinking_for_forced_tool_choice(operation)
      |> remove_conflicting_sampling_params()
      |> translate_unsupported_parameters()

    {translated_opts, []}
  end

  # Private implementation functions

  defp get_anthropic_version(user_opts) do
    Keyword.get(user_opts, :anthropic_version, @default_anthropic_version)
  end

  defp maybe_add_beta_header(request, user_opts) do
    beta_features = []

    # Add tools beta if tools are being used
    beta_features =
      if has_tools?(user_opts) do
        [@anthropic_beta_tools | beta_features]
      else
        beta_features
      end

    # Add interleaved thinking beta if thinking is enabled
    beta_features =
      if has_thinking?(user_opts) do
        ["interleaved-thinking-2025-05-14" | beta_features]
      else
        beta_features
      end

    case beta_features do
      [] ->
        request

      features ->
        beta_header = Enum.join(features, ",")
        Req.Request.put_header(request, "anthropic-beta", beta_header)
    end
  end

  defp has_tools?(user_opts) do
    tools = Keyword.get(user_opts, :tools, [])
    is_list(tools) and tools != []
  end

  defp has_thinking?(user_opts) do
    thinking = Keyword.get(user_opts, :thinking)
    reasoning_effort = Keyword.get(user_opts, :reasoning_effort)
    provider_options = Keyword.get(user_opts, :provider_options, [])
    provider_reasoning_effort = Keyword.get(provider_options, :reasoning_effort)

    not is_nil(thinking) or not is_nil(reasoning_effort) or not is_nil(provider_reasoning_effort)
  end

  defp add_basic_options(body, request_options) do
    body =
      Enum.reduce(@body_options, body, fn key, acc ->
        maybe_put(acc, key, request_options[key])
      end)

    # Handle Anthropic-specific parameters with proper names
    body
    |> maybe_put(:top_k, request_options[:anthropic_top_k])
    |> maybe_put(:metadata, request_options[:anthropic_metadata])
  end

  defp maybe_add_tools(body, options) do
    tools = get_option(options, :tools, [])

    case tools do
      [] ->
        body

      tools when is_list(tools) ->
        body = Map.put(body, :tools, Enum.map(tools, &tool_to_anthropic_format/1))

        case get_option(options, :tool_choice) do
          nil -> body
          choice -> Map.put(body, :tool_choice, choice)
        end
    end
  end

  defp get_option(options, key, default \\ nil)

  defp get_option(options, key, default) when is_list(options) do
    Keyword.get(options, key, default)
  end

  defp get_option(options, key, default) when is_map(options) do
    Map.get(options, key, default)
  end

  defp tool_to_anthropic_format(tool) do
    schema = ReqLLM.Tool.to_schema(tool, :openai)

    %{
      name: schema["function"]["name"],
      description: schema["function"]["description"],
      input_schema: schema["function"]["parameters"]
    }
  end

  defp translate_reasoning_effort(opts) do
    {reasoning_effort, opts} = Keyword.pop(opts, :reasoning_effort)
    {reasoning_budget, opts} = Keyword.pop(opts, :reasoning_token_budget)

    case reasoning_effort do
      :low ->
        budget = reasoning_budget || 1024

        opts
        |> Keyword.put(:thinking, %{type: "enabled", budget_tokens: budget})
        |> adjust_max_tokens_for_thinking(budget)
        |> adjust_top_p_for_thinking()

      :medium ->
        budget = reasoning_budget || 2048

        opts
        |> Keyword.put(:thinking, %{type: "enabled", budget_tokens: budget})
        |> adjust_max_tokens_for_thinking(budget)
        |> adjust_top_p_for_thinking()

      :high ->
        budget = reasoning_budget || 4096

        opts
        |> Keyword.put(:thinking, %{type: "enabled", budget_tokens: budget})
        |> adjust_max_tokens_for_thinking(budget)
        |> adjust_top_p_for_thinking()

      :default ->
        opts
        |> Keyword.put(:thinking, %{type: "enabled"})
        |> adjust_top_p_for_thinking()

      nil ->
        opts
    end
  end

  defp adjust_max_tokens_for_thinking(opts, budget_tokens) do
    max_tokens = Keyword.get(opts, :max_tokens)

    cond do
      is_nil(max_tokens) ->
        opts

      max_tokens <= budget_tokens ->
        Keyword.put(opts, :max_tokens, budget_tokens + 201)

      true ->
        opts
    end
  end

  defp disable_thinking_for_forced_tool_choice(opts, operation) do
    thinking = Keyword.get(opts, :thinking)
    tool_choice = Keyword.get(opts, :tool_choice)

    cond do
      is_nil(thinking) ->
        opts

      operation == :object and match?(%{type: "tool"}, tool_choice) ->
        Keyword.delete(opts, :thinking)

      match?(%{type: "tool"}, tool_choice) ->
        Keyword.delete(opts, :thinking)

      match?(%{type: "any"}, tool_choice) ->
        Keyword.put(opts, :tool_choice, %{type: "auto"})

      true ->
        opts
    end
  end

  defp adjust_top_p_for_thinking(opts) do
    opts
    |> adjust_parameter(:top_p, fn
      nil -> nil
      top_p when top_p < 0.95 -> 0.95
      top_p when top_p > 1.0 -> 1.0
      top_p -> top_p
    end)
    |> Keyword.delete(:temperature)
    |> Keyword.delete(:top_k)
  end

  defp adjust_parameter(opts, key, fun) do
    case Keyword.get(opts, key) do
      nil ->
        opts

      value ->
        case fun.(value) do
          nil -> opts
          new_value -> Keyword.put(opts, key, new_value)
        end
    end
  end

  defp remove_conflicting_sampling_params(opts) do
    has_temperature = Keyword.has_key?(opts, :temperature)
    has_top_p = Keyword.has_key?(opts, :top_p)

    if has_temperature and has_top_p do
      Keyword.delete(opts, :top_p)
    else
      opts
    end
  end

  defp translate_stop_parameter(opts) do
    case Keyword.get(opts, :stop) do
      nil ->
        opts

      stop when is_binary(stop) ->
        opts |> Keyword.delete(:stop) |> Keyword.put(:stop_sequences, [stop])

      stop when is_list(stop) ->
        opts |> Keyword.delete(:stop) |> Keyword.put(:stop_sequences, stop)
    end
  end

  defp translate_unsupported_parameters(opts) do
    Enum.reduce(@unsupported_parameters, opts, fn key, acc -> Keyword.delete(acc, key) end)
  end

  defp decode_success_response(req, resp) do
    operation = req.options[:operation]

    case operation do
      _ ->
        decode_anthropic_response(req, resp, operation)
    end
  end

  defp decode_error_response(req, resp, status) do
    reason =
      try do
        case Jason.decode(resp.body) do
          {:ok, %{"error" => %{"message" => message}}} -> message
          {:ok, %{"error" => %{"type" => error_type}}} -> "#{error_type}"
          _ -> "Anthropic API error"
        end
      rescue
        _ -> "Anthropic API error"
      end

    err =
      ReqLLM.Error.API.Response.exception(
        reason: reason,
        status: status,
        response_body: resp.body
      )

    {req, err}
  end

  defp decode_anthropic_response(req, resp, operation) do
    model_name = req.options[:model]

    # Handle case where model_name might be nil
    model =
      case model_name do
        nil ->
          case req.private[:req_llm_model] do
            %ReqLLM.Model{} = stored_model -> stored_model
            _ -> %ReqLLM.Model{provider: :anthropic, model: "unknown"}
          end

        model_name when is_binary(model_name) ->
          %ReqLLM.Model{provider: :anthropic, model: model_name}
      end

    is_streaming = req.options[:stream] == true

    if is_streaming do
      decode_streaming_response(req, resp, model_name)
    else
      decode_non_streaming_response(req, resp, model, operation)
    end
  end

  defp decode_streaming_response(req, resp, model_name) do
    # Similar structure to defaults but use Anthropic-specific stream handling
    {stream, provider_meta} =
      case resp.body do
        %Stream{} = existing_stream ->
          {existing_stream, %{}}

        _ ->
          # Real-time streaming - use the stream created by Stream step
          # The request has already been initiated by the initial Req.request call
          # We just need to return the configured stream, not make another request
          real_time_stream = Req.Request.get_private(req, :real_time_stream, [])

          {real_time_stream, %{}}
      end

    response = %ReqLLM.Response{
      id: "stream-#{System.unique_integer([:positive])}",
      model: model_name,
      context: req.options[:context] || %ReqLLM.Context{messages: []},
      message: nil,
      stream?: true,
      stream: stream,
      usage: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        cached_tokens: 0,
        reasoning_tokens: 0
      },
      finish_reason: nil,
      provider_meta: provider_meta
    }

    {req, %{resp | body: response}}
  end

  defp decode_non_streaming_response(req, resp, model, operation) do
    body = ensure_parsed_body(resp.body)
    {:ok, response} = ReqLLM.Providers.Anthropic.Response.decode_response(body, model)

    final_response =
      case operation do
        :object ->
          extract_and_set_object(response)

        _ ->
          response
      end

    merged_response = merge_response_with_context(req, final_response)
    {req, %{resp | body: merged_response}}
  end

  defp extract_and_set_object(response) do
    extracted_object =
      case ReqLLM.Response.tool_calls(response) do
        [] ->
          nil

        tool_calls ->
          case Enum.find(tool_calls, &(&1.name == "structured_output")) do
            nil -> nil
            %{arguments: object} -> object
          end
      end

    %{response | object: extracted_object}
  end

  defp merge_response_with_context(req, response) do
    context = req.options[:context] || %ReqLLM.Context{messages: []}
    ReqLLM.Context.merge_response(context, response)
  end

  defp default_max_tokens(_model_name), do: 1024
end
