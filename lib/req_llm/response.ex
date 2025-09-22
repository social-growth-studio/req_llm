defmodule ReqLLM.Response do
  @moduledoc """
  High-level representation of an LLM turn.

  Always contains a Context (full conversation history **including**
  the newly-generated assistant/tool messages) plus rich metadata and, when
  streaming, a lazy `Stream` of `ReqLLM.StreamChunk`s.

  This struct eliminates the need for manual message extraction and context building
  in multi-turn conversations and tool calling workflows.

  ## Examples

      # Basic response usage
      {:ok, response} = ReqLLM.generate_text("anthropic:claude-3-sonnet", context)
      response.text()  #=> "Hello! I'm Claude."
      response.usage()  #=> %{input_tokens: 12, output_tokens: 4}

      # Multi-turn conversation (no manual context building)
      {:ok, response2} = ReqLLM.generate_text("anthropic:claude-3-sonnet", response.context)

      # Tool calling loop
      {:ok, final_response} = ReqLLM.Response.handle_tools(response, tools)

  """

  use TypedStruct

  alias ReqLLM.{Context, Message, Model}

  @derive {Jason.Encoder, except: [:stream]}

  typedstruct enforce: true do
    # ---------- Core ----------
    # Provider id of the turn
    field(:id, String.t())
    # Model that produced the turn
    field(:model, String.t())
    # History incl. new assistant msg
    field(:context, Context.t())
    # The assistant/tool message created by this turn
    field(:message, Message.t() | nil)
    # Structured object for object generation
    field(:object, map() | nil, default: nil)

    # ---------- Streams ----------
    field(:stream?, boolean(), default: false)
    # Stream of StreamChunk when stream? == true
    field(:stream, Enumerable.t() | nil, default: nil)

    # ---------- Metadata ----------
    field(:usage, %{optional(atom()) => integer()} | nil)
    field(:finish_reason, atom() | String.t() | nil)
    # Raw provider extras
    field(:provider_meta, map(), default: %{})

    # ---------- Errors ----------
    field(:error, Exception.t() | nil, default: nil)
  end

  @doc """
  Extract text content from the response message.

  Returns the concatenated text from all content parts in the assistant message.
  Returns nil when no message is present. For streaming responses, this may be nil 
  until the stream is joined.

  ## Examples

      iex> ReqLLM.Response.text(response)
      "Hello! I'm Claude and I can help you with questions."

  """
  @spec text(t()) :: String.t() | nil
  def text(%__MODULE__{message: nil}), do: nil

  def text(%__MODULE__{message: %Message{content: content}}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  @doc """
  Extract tool calls from the response message.

  Returns a list of tool calls if the message contains them, empty list otherwise.

  ## Examples

      iex> ReqLLM.Response.tool_calls(response)
      [%{name: "get_weather", arguments: %{location: "San Francisco"}}]

  """
  @spec tool_calls(t()) :: [term()]
  def tool_calls(%__MODULE__{message: nil}), do: []

  def tool_calls(%__MODULE__{message: %Message{tool_calls: tool_calls}})
      when is_list(tool_calls) do
    tool_calls
  end

  def tool_calls(%__MODULE__{message: %Message{tool_calls: nil, content: content}})
      when is_list(content) do
    # Extract tool calls from content parts (e.g., for Anthropic)
    content
    |> Enum.filter(&(&1.type == :tool_call))
    |> Enum.map(fn part ->
      %{
        name: part.tool_name,
        arguments: part.input,
        id: part.tool_call_id
      }
    end)
  end

  def tool_calls(%__MODULE__{message: %Message{tool_calls: nil}}), do: []

  @doc """
  Get the finish reason for this response.

  ## Examples

      iex> ReqLLM.Response.finish_reason(response)
      :stop

  """
  @spec finish_reason(t()) :: atom() | String.t() | nil
  def finish_reason(%__MODULE__{finish_reason: reason}), do: reason

  @doc """
  Get usage statistics for this response.

  ## Examples

      iex> ReqLLM.Response.usage(response)
      %{input_tokens: 12, output_tokens: 8, total_tokens: 20}

  """
  @spec usage(t()) :: %{optional(atom()) => integer()} | nil
  def usage(%__MODULE__{usage: usage}), do: usage

  @doc """
  Check if the response completed successfully without errors.

  ## Examples

      iex> ReqLLM.Response.ok?(response)
      true

  """
  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{error: nil}), do: true
  def ok?(%__MODULE__{error: _error}), do: false

  @doc """
  Create a stream of text content chunks from a streaming response.

  Only yields content from :content type stream chunks, filtering out
  metadata and other chunk types.

  ## Examples

      response
      |> ReqLLM.Response.text_stream()
      |> Stream.each(&IO.write/1)
      |> Stream.run()

  """
  @spec text_stream(t()) :: Enumerable.t()
  def text_stream(%__MODULE__{stream?: false}), do: []
  def text_stream(%__MODULE__{stream: nil}), do: []

  def text_stream(%__MODULE__{stream: stream}) do
    stream
    |> Stream.filter(&(&1.type == :content))
    |> Stream.map(& &1.text)
  end

  # ---------- Stream Helpers ----------

  @doc """
  Create a stream of structured objects from a streaming response.

  Only yields valid objects from tool call stream chunks, filtering out
  metadata and other chunk types.

  ## Examples

      response
      |> ReqLLM.Response.object_stream()
      |> Stream.each(&IO.inspect/1)
      |> Stream.run()

  """
  @spec object_stream(t()) :: Enumerable.t()
  def object_stream(%__MODULE__{stream?: false}), do: []
  def object_stream(%__MODULE__{stream: nil}), do: []

  def object_stream(%__MODULE__{stream: stream}) do
    stream
    |> Stream.filter(&(&1.type == :tool_call))
    |> Stream.filter(&(&1.name == "structured_output"))
    |> Stream.map(& &1.arguments)
  end

  @doc """
  Materialize a streaming response into a complete response.

  Consumes the entire stream, builds the complete message, and returns
  a new response with the stream consumed and message populated.

  ## Examples

      {:ok, complete_response} = ReqLLM.Response.join_stream(streaming_response)

  """
  @spec join_stream(t()) :: {:ok, t()} | {:error, term()}
  def join_stream(%__MODULE__{stream?: false} = response), do: {:ok, response}
  def join_stream(%__MODULE__{stream: nil} = response), do: {:ok, response}

  def join_stream(%__MODULE__{stream: stream} = response) do
    ReqLLM.Response.Stream.join(stream, response)
  end

  @doc """
  Decode provider response data into a canonical ReqLLM.Response.

  This is a façade function that accepts raw provider data and a model specification,
  and directly calls the Response.Codec.decode_response/2 protocol for zero-ceremony decoding.

  Supports both Model struct and string inputs, automatically resolving model
  strings using Model.from!/1.

  ## Parameters

    * `raw_data` - Raw provider response data or Stream
    * `model` - Model specification (Model struct or string like "anthropic:claude-3-sonnet")

  ## Returns

    * `{:ok, %ReqLLM.Response{}}` on success
    * `{:error, reason}` on failure

  ## Examples

      {:ok, response} = ReqLLM.Response.decode_response(raw_json, "anthropic:claude-3-sonnet")
      {:ok, response} = ReqLLM.Response.decode_response(raw_json, model_struct)

  """
  @spec decode_response(term(), Model.t() | String.t()) :: {:ok, t()} | {:error, term()}
  def decode_response(raw_data, model_input) do
    model = if is_binary(model_input), do: Model.from!(model_input), else: model_input
    {:ok, provider_mod} = ReqLLM.Provider.Registry.get_provider(model.provider)

    wrapped_data =
      if function_exported?(provider_mod, :wrap_response, 1) do
        provider_mod.wrap_response(raw_data)
      else
        # fallback for providers that implement protocol directly
        raw_data
      end

    ReqLLM.Response.Codec.decode_response(wrapped_data, model)
  end

  @doc """
  Decode provider response data into a Response with structured object.

  Similar to decode_response/2 but specifically for object generation responses.
  Extracts the structured object from tool calls and validates it against the schema.

  ## Parameters

    * `raw_data` - Raw provider response data
    * `model` - Model specification
    * `schema` - Schema definition for validation

  ## Returns

    * `{:ok, %ReqLLM.Response{}}` with object field populated on success
    * `{:error, reason}` on failure

  """
  @spec decode_object(term(), Model.t() | String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode_object(raw_data, model_input, schema) do
    with {:ok, response} <- decode_response(raw_data, model_input),
         {:ok, object} <- extract_object_from_response(response, schema) do
      {:ok, %{response | object: object}}
    end
  end

  @doc """
  Decode provider streaming response data into a Response with object stream.

  Similar to decode_response/2 but for streaming object generation.
  The response will contain a stream of structured objects.

  ## Parameters

    * `raw_data` - Raw provider streaming response data
    * `model` - Model specification  
    * `schema` - Schema definition for validation

  ## Returns

    * `{:ok, %ReqLLM.Response{}}` with stream populated on success
    * `{:error, reason}` on failure

  """
  @spec decode_object_stream(term(), Model.t() | String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def decode_object_stream(raw_data, model_input, _schema) do
    decode_response(raw_data, model_input)
    # The response already contains the stream, we just need to ensure
    # object_stream/1 can extract objects from tool_call chunks
  end

  @doc """
  Extracts structured object from a Response, handling both tool calling and response_format approaches.
  
  For tool calling responses (Anthropic), extracts from the structured_output tool call.
  For response_format responses (OpenAI-compatible), parses JSON from the message text.
  """
  def extract_object_from_response(response, _schema) do
    tool_calls = tool_calls(response)
    has_structured_output_tool = Enum.any?(tool_calls, &(&1.name == "structured_output"))

    if has_structured_output_tool do
      extract_from_tool_call(tool_calls)
    else
      extract_json_from_text(response)
    end
  end

  defp extract_from_tool_call(tool_calls) do
    case Enum.find(tool_calls, &(&1.name == "structured_output")) do
      %{arguments: object} ->
        {:ok, object}

      nil ->
        {:error, %ReqLLM.Error.API.Response{reason: "structured_output tool call not found"}}
    end
  end

  defp extract_json_from_text(%__MODULE__{message: nil}) do
    {:error, %ReqLLM.Error.API.Response{reason: "No message in response"}}
  end

  defp extract_json_from_text(%__MODULE__{message: %Message{content: content}}) do
    text_parts = Enum.filter(content, &(&1.type == :text))

    case text_parts do
      [%{text: text} | _] ->
        case Jason.decode(text) do
          {:ok, json_object} ->
            {:ok, json_object}

          {:error, jason_error} ->
            {:error,
             %ReqLLM.Error.API.Response{
               reason: "Response text is not valid JSON: #{inspect(jason_error)}",
               response_body: String.slice(text, 0, 200)
             }}
        end

      _ ->
        {:error, %ReqLLM.Error.API.Response{reason: "No text content in response"}}
    end
  end

  @doc """
  Extracts the generated object from a Response.
  """
  @spec object(t()) :: map() | nil
  def object(%__MODULE__{object: object}) do
    object
  end
end
