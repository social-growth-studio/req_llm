defmodule ReqLLM.Message.ContentPart do
  @moduledoc """
  ContentPart represents a single piece of content within a message.

  Supports multiple content types:
  - `:text` - Plain text content
  - `:image_url` - Image from URL
  - `:image` - Image from binary data
  - `:file` - File attachment with inline data
  - `:file_uri` - File reference by URI (e.g., Google File API URI)
  - `:thinking` - Chain-of-thought thinking content

  ## See also

  - `ReqLLM.Message` - Multi-modal message composition using ContentPart collections
  """

  use TypedStruct

  typedstruct enforce: true do
    field(:type, :text | :image_url | :image | :file | :file_uri | :thinking, enforce: true)

    field(:text, String.t() | nil, default: nil)
    field(:url, String.t() | nil, default: nil)
    field(:data, binary() | nil, default: nil)
    field(:media_type, String.t() | nil, default: nil)
    field(:filename, String.t() | nil, default: nil)
    field(:metadata, map(), default: %{})
  end

  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{type: type}) when is_atom(type), do: true
  def valid?(_), do: false

  @spec text(String.t()) :: t()
  def text(content), do: %__MODULE__{type: :text, text: content}

  @spec text(String.t(), map()) :: t()
  def text(content, metadata), do: %__MODULE__{type: :text, text: content, metadata: metadata}

  @spec thinking(String.t()) :: t()
  def thinking(content), do: %__MODULE__{type: :thinking, text: content}

  @spec thinking(String.t(), map()) :: t()
  def thinking(content, metadata),
    do: %__MODULE__{type: :thinking, text: content, metadata: metadata}

  @spec image_url(String.t()) :: t()
  def image_url(url), do: %__MODULE__{type: :image_url, url: url}

  @spec image(binary(), String.t()) :: t()
  def image(data, media_type \\ "image/png"),
    do: %__MODULE__{type: :image, data: data, media_type: media_type}

  @spec file(binary(), String.t(), String.t()) :: t()
  def file(data, filename, media_type \\ "application/octet-stream"),
    do: %__MODULE__{type: :file, data: data, filename: filename, media_type: media_type}

  @spec file_uri(String.t(), String.t()) :: t()
  def file_uri(uri, media_type),
    do: %__MODULE__{type: :file_uri, url: uri, media_type: media_type}

  defimpl Inspect do
    def inspect(%{type: type} = part, opts) do
      content_desc =
        case type do
          :text -> inspect_text(part.text, opts)
          :thinking -> inspect_text(part.text, opts)
          :image_url -> "url: #{part.url}"
          :image -> "#{part.media_type} (#{byte_size(part.data)} bytes)"
          :file -> "#{part.media_type} (#{byte_size(part.data || <<>>)} bytes)"
          :file_uri -> "uri: #{part.url}, mime: #{part.media_type}"
        end

      Inspect.Algebra.concat([
        "#ContentPart<",
        Inspect.Algebra.to_doc(type, opts),
        " ",
        content_desc,
        ">"
      ])
    end

    defp inspect_text(text, _opts) when is_nil(text), do: "nil"

    defp inspect_text(text, _opts) do
      truncated = String.slice(text, 0, 30)
      if String.length(text) > 30, do: "\"#{truncated}...\"", else: "\"#{truncated}\""
    end
  end

  defimpl Jason.Encoder do
    def encode(%{data: data} = part, opts) when is_binary(data) do
      encoded_part = %{part | data: Base.encode64(data)}
      Jason.Encode.map(Map.from_struct(encoded_part), opts)
    end

    def encode(part, opts) do
      Jason.Encode.map(Map.from_struct(part), opts)
    end
  end
end
