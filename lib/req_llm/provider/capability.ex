defmodule ReqLLM.Provider.Capability do
  @moduledoc """
  Behavior for provider-specific capabilities that extend beyond standard operations.

  Provider capabilities are optional modules that provide additional functionality like:
  - File uploads (Google, Anthropic)
  - Fine-tuning management (OpenAI)
  - Batch processing APIs
  - Model training (custom providers)

  Capabilities handle their own HTTP requests but should:
  - Use the provider's authentication via ReqLLM.Keys
  - Use the provider's base_url configuration when possible
  - Use Req for HTTP requests (not Finch directly)
  - Follow ReqLLM error handling patterns with Splode errors

  ## Example

      defmodule ReqLLM.Providers.Google.Files do
        @behaviour ReqLLM.Provider.Capability

        @impl true
        def capability_name, do: :files

        @impl true
        def supported_operations, do: [:upload, :get, :delete, :list]

        def upload(file_data, mime_type, display_name, opts \\\\ []) do
          api_key = ReqLLM.Keys.get!(:google, opts)
          base_url = opts[:base_url] || ReqLLM.Providers.Google.default_base_url()

          # Make HTTP requests using Req
        end
      end

  ## Discovery

  Capabilities are discovered by convention:
  - Module name: `ReqLLM.Providers.{Provider}.{Capability}`
  - Example: `ReqLLM.Providers.Google.Files`

  Use `ReqLLM.Capability.provider_supports?/2` to check if a provider supports a capability.
  """

  @doc """
  Returns the name of this capability.

  This is used for capability discovery and should be a simple atom like `:files`, `:batches`, etc.

  ## Examples

      @impl true
      def capability_name, do: :files
  """
  @callback capability_name() :: atom()

  @doc """
  Returns the list of operations supported by this capability.

  ## Examples

      @impl true
      def supported_operations, do: [:upload, :get, :delete, :list]
  """
  @callback supported_operations() :: [atom()]
end
