defmodule ReqLLM.Provider.Registry do
  @moduledoc """
  Registry for AI providers and their supported models.

  The registry uses `:persistent_term` for efficient, read-heavy access patterns typical
  in AI applications. Providers are registered at compile time through the DSL, ensuring
  all available providers and models are known at startup.

  ## Storage Format

  The registry stores providers as:

      %{
        provider_id => %{
          module: Module,
          metadata: %{models: [...], capabilities: [...], ...}
        }
      }

  ## Usage Examples

      # Get a provider module
      {:ok, module} = ReqLLM.Provider.Registry.get_provider(:anthropic)
      module #=> ReqLLM.Providers.Anthropic

      # Get model information
      {:ok, model} = ReqLLM.Provider.Registry.get_model(:anthropic, "claude-3-sonnet")
      model.metadata.context_length #=> 200000

      # Check if a model exists
      ReqLLM.Provider.Registry.model_exists?("anthropic:claude-3-sonnet") #=> true

      # List all providers
      ReqLLM.Provider.Registry.list_providers() #=> [:anthropic, :openai, :github_models]

      # List models for a provider
      ReqLLM.Provider.Registry.list_models(:anthropic) #=> ["claude-3-sonnet", "claude-3-haiku", ...]

  ## Integration

  The registry is automatically populated by providers using `ReqLLM.Provider.DSL`:

      defmodule MyProvider do
        use ReqLLM.Provider.DSL,
          id: :my_provider,
          base_url: "https://api.example.com/v1",
          metadata: "priv/models_dev/my_provider.json"

        # Provider implementation...
      end

  The DSL calls `register/3` during compilation to add the provider to the registry.

  """

  @registry_key :req_llm_providers

  @doc """
  Registers a provider in the global registry.

  Called automatically by the DSL during compilation. Should not be called manually.

  ## Parameters

    * `provider_id` - Unique identifier for the provider (atom)
    * `module` - The provider module implementing Req plugin pattern
    * `metadata` - Provider metadata including supported models

  ## Examples

      ReqLLM.Provider.Registry.register(:my_provider, MyProvider, %{
        models: ["model-1", "model-2"],
        capabilities: [:text_generation, :embeddings]
      })

  """
  @spec register(atom(), module(), map()) ::
          :ok | {:error, {:already_registered, module()} | {:validation_error, term()}}
  def register(provider_id, module, metadata) when is_atom(provider_id) and is_atom(module) do
    current_providers = get_registry()

    # Validate metadata if provided
    case validate_metadata(metadata) do
      :ok ->
        case Map.get(current_providers, provider_id) do
          nil ->
            updated_registry =
              Map.put(current_providers, provider_id, %{
                module: module,
                metadata: metadata || %{}
              })

            :persistent_term.put(@registry_key, updated_registry)
            :ok

          %{module: ^module} ->
            # Idempotent registration
            :ok

          %{module: other} ->
            require Logger

            Logger.warning(
              "Attempted to overwrite provider #{provider_id}: existing=#{inspect(other)}, attempted=#{inspect(module)}"
            )

            {:error, {:already_registered, other}}
        end

      {:error, validation_error} ->
        {:error, {:validation_error, validation_error}}
    end
  end

  @doc """
  Retrieves a provider module by ID.

  ## Parameters

    * `provider_id` - The provider identifier (atom)

  ## Returns

    * `{:ok, module}` - Provider module found
    * `{:error, :not_found}` - Provider not registered
    * `{:error, :not_implemented}` - Provider exists but has no implementation (metadata-only)

  ## Examples

      {:ok, module} = ReqLLM.Provider.Registry.get_provider(:anthropic)
      module #=> ReqLLM.Providers.Anthropic

      ReqLLM.Provider.Registry.get_provider(:unknown)
      #=> {:error, :not_found}

  """
  @spec get_provider(atom()) :: {:ok, module()} | {:error, :not_found | :not_implemented}
  def get_provider(provider_id) when is_atom(provider_id) do
    case get_registry() do
      %{^provider_id => %{module: nil}} -> {:error, :not_implemented}
      %{^provider_id => %{module: module}} -> {:ok, module}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Alias for get_provider/1 to match legacy API expectations.
  """
  @spec fetch(atom()) :: {:ok, module()} | {:error, :not_found | :not_implemented}
  def fetch(provider_id), do: get_provider(provider_id)

  @doc """
  Retrieves model information for a specific provider and model.

  ## Parameters

    * `provider_id` - The provider identifier (atom)
    * `model_name` - The model name (string)

  ## Returns

    * `{:ok, model}` - ReqLLM.Model struct with metadata
    * `{:error, :provider_not_found}` - Provider not registered
    * `{:error, :model_not_found}` - Model not supported by provider

  ## Examples

      {:ok, model} = ReqLLM.Provider.Registry.get_model(:anthropic, "claude-3-sonnet")
      model.metadata.context_length #=> 200000
      model.metadata.pricing.input  #=> 0.003

      ReqLLM.Provider.Registry.get_model(:anthropic, "unknown-model")
      #=> {:error, :model_not_found}

  """
  @spec get_model(atom(), String.t()) ::
          {:ok, ReqLLM.Model.t()} | {:error, :provider_not_found | :model_not_found}
  def get_model(provider_id, model_name) when is_atom(provider_id) and is_binary(model_name) do
    case get_provider_info(provider_id) do
      {:ok, provider_info} ->
        case find_model_metadata(provider_info, model_name) do
          {:ok, model_metadata} ->
            # Create enhanced model with structured fields populated from metadata
            limit =
              get_in(model_metadata, ["limit"])
              |> ReqLLM.Metadata.map_string_keys_to_atoms()

            modalities =
              get_in(model_metadata, ["modalities"])
              |> ReqLLM.Metadata.map_string_keys_to_atoms()
              |> ReqLLM.Metadata.convert_modality_values()

            capabilities = ReqLLM.Metadata.build_capabilities_from_metadata(model_metadata)

            cost =
              get_in(model_metadata, ["cost"]) |> ReqLLM.Metadata.map_string_keys_to_atoms()

            enhanced_model =
              ReqLLM.Model.new(provider_id, model_name,
                limit: limit,
                modalities: modalities,
                capabilities: capabilities,
                cost: cost
              )

            # Add raw metadata for backward compatibility and additional fields
            model_with_metadata = Map.put(enhanced_model, :_metadata, model_metadata)
            {:ok, model_with_metadata}

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc """
  Retrieves model information with bang syntax (raises on error).

  Same as `get_model/2` but raises `ArgumentError` instead of returning error tuples.

  ## Parameters

    * `model_spec` - Model specification string (e.g., "anthropic:claude-3-sonnet")

  ## Examples

      model = ReqLLM.Provider.Registry.get_model!("anthropic:claude-3-sonnet")
      model.metadata.context_length #=> 200000

      ReqLLM.Provider.Registry.get_model!("unknown:model")
      #=> ** (ArgumentError) Provider not found: unknown

  """
  @dialyzer {:nowarn_function, get_model!: 1}
  @spec get_model!(String.t()) :: ReqLLM.Model.t() | no_return()
  def get_model!(model_spec) when is_binary(model_spec) do
    case parse_model_spec(model_spec) do
      {:ok, provider_id, model_name} ->
        result = get_model(provider_id, model_name)

        case result do
          {:ok, model} ->
            model

          {:error, :provider_not_found} ->
            raise ArgumentError, "Provider not found: #{provider_id}"

          {:error, :model_not_found} ->
            raise ArgumentError, "Model not found: #{provider_id}:#{model_name}"

          _ ->
            raise ArgumentError, "Failed to retrieve model: #{provider_id}:#{model_name}"
        end

      {:error, reason} ->
        raise ArgumentError, "Invalid model specification '#{model_spec}': #{reason}"
    end
  end

  @doc """
  Lists all registered provider IDs.

  ## Returns

  List of provider atoms in registration order.

  ## Examples

      ReqLLM.Provider.Registry.list_providers()
      #=> [:anthropic, :openai, :github_models]

  """
  @spec list_providers() :: [atom()]
  def list_providers do
    get_registry()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Lists only fully implemented providers (have modules).

  ## Returns

  List of provider atoms that can actually make API calls.

  ## Examples

      ReqLLM.Provider.Registry.list_implemented_providers()
      #=> [:anthropic, :openai]

  """
  @spec list_implemented_providers() :: [atom()]
  def list_implemented_providers do
    get_registry()
    |> Enum.filter(fn {_id, info} -> Map.get(info, :implemented, false) end)
    |> Enum.map(fn {id, _info} -> id end)
    |> Enum.sort()
  end

  @doc """
  Lists providers that exist only as metadata (no implementation).

  ## Returns

  List of provider atoms that have metadata but no implementation.

  ## Examples

      ReqLLM.Provider.Registry.list_metadata_only_providers()
      #=> [:mistral, :openrouter, :groq]

  """
  @spec list_metadata_only_providers() :: [atom()]
  def list_metadata_only_providers do
    get_registry()
    |> Enum.filter(fn {_id, info} -> !Map.get(info, :implemented, true) end)
    |> Enum.map(fn {id, _info} -> id end)
    |> Enum.sort()
  end

  @doc """
  Checks if a provider is fully implemented.

  ## Parameters

    * `provider_id` - The provider identifier (atom)

  ## Returns

    * `true` - Provider has both module and metadata
    * `false` - Provider is metadata-only or doesn't exist

  ## Examples

      ReqLLM.Provider.Registry.implemented?(:anthropic)
      #=> true

      ReqLLM.Provider.Registry.implemented?(:mistral)
      #=> false (metadata-only)

  """
  @spec implemented?(atom()) :: boolean()
  def implemented?(provider_id) when is_atom(provider_id) do
    case get_provider_info(provider_id) do
      {:ok, info} -> Map.get(info, :implemented, false)
      {:error, _} -> false
    end
  end

  @doc """
  Retrieves complete provider metadata by ID.

  ## Parameters

    * `provider_id` - The provider identifier (atom)

  ## Returns

    * `{:ok, metadata}` - Provider metadata map
    * `{:error, :not_found}` - Provider not registered

  ## Examples

      {:ok, metadata} = ReqLLM.Provider.Registry.get_provider_metadata(:anthropic)
      env_vars = get_in(metadata, ["provider", "env"])
      env_vars #=> ["ANTHROPIC_API_KEY"]

  """
  @spec get_provider_metadata(atom()) :: {:ok, map()} | {:error, :not_found}
  def get_provider_metadata(provider_id) when is_atom(provider_id) do
    case get_provider_info(provider_id) do
      {:ok, %{metadata: metadata}} -> {:ok, metadata}
      error -> error
    end
  end

  @doc """
  Lists all model names supported by a provider.

  ## Parameters

    * `provider_id` - The provider identifier (atom)

  ## Returns

    * `{:ok, models}` - List of model name strings
    * `{:error, :not_found}` - Provider not registered

  ## Examples

      {:ok, models} = ReqLLM.Provider.Registry.list_models(:anthropic)
      models #=> ["claude-3-sonnet", "claude-3-haiku", "claude-3-opus"]

      ReqLLM.Provider.Registry.list_models(:unknown)
      #=> {:error, :not_found}

  """
  @spec list_models(atom()) :: {:ok, [String.t()]} | {:error, :provider_not_found}
  def list_models(provider_id) when is_atom(provider_id) do
    case get_provider_info(provider_id) do
      {:ok, %{metadata: %{models: models}}} when is_list(models) ->
        model_names =
          Enum.map(models, fn
            %{"id" => id} -> id
            %{id: id} -> id
            model when is_binary(model) -> model
            _ -> nil
          end)
          |> Enum.filter(&is_binary/1)
          |> Enum.sort()

        {:ok, model_names}

      {:ok, _} ->
        {:ok, []}

      error ->
        error
    end
  end

  @doc """
  Checks if a model specification exists in the registry.

  ## Parameters

    * `model_spec` - Model specification string (e.g., "anthropic:claude-3-sonnet")

  ## Returns

  Boolean indicating if the model exists.

  ## Examples

      ReqLLM.Provider.Registry.model_exists?("anthropic:claude-3-sonnet") #=> true
      ReqLLM.Provider.Registry.model_exists?("unknown:model") #=> false

  """
  @spec model_exists?(String.t()) :: boolean()
  @dialyzer {:nowarn_function, model_exists?: 1}
  def model_exists?(model_spec) when is_binary(model_spec) do
    case parse_model_spec(model_spec) do
      {:ok, provider_id, model_name} ->
        case get_model(provider_id, model_name) do
          {:ok, _} -> true
          {:error, _} -> false
        end

      {:error, _} ->
        false
    end
  end

  @doc """
  Initializes the provider registry by discovering and registering all provider modules.

  This function scans for modules that implement the `ReqLLM.Provider` behaviour
  and registers them automatically.
  """
  @spec initialize() :: :ok
  def initialize do
    require Logger

    providers = discover_providers()

    # Use Task.async_stream for parallel provider info extraction
    {registry_map, failed_modules} =
      providers
      |> Task.async_stream(&extract_provider_info/1, ordered: false, timeout: 5000)
      |> Enum.reduce({%{}, []}, fn
        {:ok, {:ok, {id, module, metadata}}}, {acc, failed} ->
          {Map.put(acc, id, %{module: module, metadata: metadata, implemented: true}), failed}

        {:ok, {:error, {module, error}}}, {acc, failed} ->
          {acc, [{module, error} | failed]}

        {:exit, reason}, {acc, failed} ->
          {acc, [{:unknown_module, reason} | failed]}
      end)

    # Also register JSON-only providers (providers without modules)
    json_only_registry = register_json_only_providers(registry_map)
    final_registry = Map.merge(registry_map, json_only_registry)

    # Log any failures in a batch
    if !Enum.empty?(failed_modules) do
      Logger.warning(
        "Failed to register #{length(failed_modules)} providers: #{inspect(failed_modules)}"
      )
    end

    # Store in persistent_term
    :persistent_term.put(@registry_key, final_registry)

    Logger.debug(
      "ReqLLM provider registry initialized with #{map_size(final_registry)} providers (#{map_size(registry_map)} implemented, #{map_size(json_only_registry)} metadata-only)"
    )

    :ok
  end

  @spec reload() :: :ok
  def reload, do: initialize()

  @doc """
  Clears the provider registry.

  Mainly useful for testing.
  """
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@registry_key)
    :ok
  end

  # Private helper functions

  @doc false
  @spec extract_provider_info(module()) ::
          {:ok, {atom(), module(), map()}} | {:error, {module(), term()}}
  def extract_provider_info(module) do
    # Get provider metadata from DSL compilation
    metadata =
      if Code.ensure_loaded?(module) and function_exported?(module, :metadata, 0) do
        module.metadata()
      else
        %{}
      end

    # Get provider ID from DSL function or fallback methods
    provider_id =
      cond do
        function_exported?(module, :provider_id, 0) ->
          module.provider_id()

        function_exported?(module, :provider_info, 0) ->
          module.provider_info().id

        true ->
          # Fallback: extract from module name
          extract_provider_id_from_module_name(module)
      end

    {:ok, {provider_id, module, metadata}}
  rescue
    error ->
      {:error, {module, Exception.message(error)}}
  catch
    :exit, reason ->
      {:error, {module, reason}}
  end

  @doc false
  @spec discover_providers() :: [module()]
  def discover_providers do
    case :application.get_key(:req_llm, :modules) do
      {:ok, modules} -> Enum.filter(modules, &provider_module?/1)
      :undefined -> []
    end
  end

  @doc false
  @spec provider_module?(module()) :: boolean()
  def provider_module?(module) do
    behaviours = module.__info__(:attributes)[:behaviour] || []
    ReqLLM.Provider in behaviours
  rescue
    _ -> false
  end

  defp extract_provider_id_from_module_name(module) do
    module
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
    |> String.downcase()
    |> String.to_atom()
  end

  defp get_registry do
    :persistent_term.get(@registry_key, %{})
  end

  @spec get_provider_info(atom()) :: {:ok, map()} | {:error, :provider_not_found}
  defp get_provider_info(provider_id) do
    case get_registry() do
      %{^provider_id => provider_info} -> {:ok, provider_info}
      _ -> {:error, :provider_not_found}
    end
  end

  defp find_model_metadata(%{metadata: %{models: models}}, model_name) when is_list(models) do
    model_data =
      Enum.find(models, fn
        %{"id" => ^model_name} -> true
        %{id: ^model_name} -> true
        ^model_name -> true
        _ -> false
      end)

    case model_data do
      nil -> {:error, :model_not_found}
      %{"id" => _} = data -> {:ok, data}
      %{id: _} = data -> {:ok, data}
      ^model_name -> {:ok, %{"id" => model_name}}
    end
  end

  defp find_model_metadata(%{metadata: metadata}, _model_name) do
    # Provider has no models list, return basic metadata
    {:ok, metadata}
  end

  defp parse_model_spec(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider_str, model_name] ->
        provider_id = String.to_existing_atom(provider_str)
        {:ok, provider_id, model_name}

      [_single_part] ->
        {:error, "Model specification must be in format 'provider:model'"}
    end
  rescue
    ArgumentError ->
      {:error, "Unknown provider in specification"}
  end

  @doc false
  # Register providers that exist only as JSON metadata files
  defp register_json_only_providers(existing_registry) do
    priv_dir = Application.app_dir(:req_llm, "priv")
    models_dir = Path.join(priv_dir, "models_dev")

    if File.dir?(models_dir) do
      models_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(&String.trim_trailing(&1, ".json"))
      |> Enum.reduce(%{}, fn filename, acc ->
        provider_id = filename_to_provider_atom(filename)

        # Skip if already registered or if we can't convert to atom
        if provider_id && !Map.has_key?(existing_registry, provider_id) do
          case load_json_metadata(models_dir, filename) do
            {:ok, metadata} ->
              Map.put(acc, provider_id, %{module: nil, metadata: metadata, implemented: false})

            {:error, _} ->
              acc
          end
        else
          acc
        end
      end)
    else
      %{}
    end
  end

  @doc false
  # Convert filename to provider atom
  defp filename_to_provider_atom(filename) do
    # Convert hyphenated names to underscored atoms, but keep original if it's already valid
    atom_candidate = String.replace(filename, "-", "_")

    # Try to create atom safely
    try do
      String.to_atom(atom_candidate)
    rescue
      SystemLimitError ->
        # Atom table is full
        nil
    end
  end

  @doc false
  # Load metadata from a JSON file for a provider
  defp load_json_metadata(models_dir, filename) do
    file_path = Path.join(models_dir, "#{filename}.json")

    with {:ok, content} <- File.read(file_path),
         {:ok, data} <- Jason.decode(content) do
      # Convert string keys to atom keys for easier access
      {:ok, atomize_json_keys(data)}
    end
  end

  @doc false
  # Helper to recursively convert string keys to atoms (for known keys only)
  defp atomize_json_keys(data) when is_map(data) do
    data
    |> Map.new(fn
      {"models", value} -> {:models, atomize_json_keys(value)}
      {"capabilities", value} -> {:capabilities, value}
      {"pricing", value} -> {:pricing, atomize_json_keys(value)}
      {"context_length", value} -> {:context_length, value}
      {"id", value} -> {:id, value}
      {"input", value} -> {:input, value}
      {"output", value} -> {:output, value}
      {key, value} -> {key, atomize_json_keys(value)}
    end)
  end

  defp atomize_json_keys(data) when is_list(data) do
    Enum.map(data, &atomize_json_keys/1)
  end

  defp atomize_json_keys(data), do: data

  # Validates provider metadata using the consolidated ReqLLM.Metadata module
  defp validate_metadata(nil), do: :ok
  defp validate_metadata(%{} = metadata) when metadata == %{}, do: :ok

  defp validate_metadata(metadata) when is_map(metadata) do
    with {:ok, _} <- validate_provider_config(metadata),
         {:ok, _} <- validate_models_metadata(metadata) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp validate_metadata(_), do: {:error, "Metadata must be a map"}

  # Validate provider-level configuration
  defp validate_provider_config(metadata) do
    case Map.get(metadata, :provider) || Map.get(metadata, "provider") do
      nil ->
        {:ok, nil}

      provider_config when is_map(provider_config) ->
        # Only validate if the config has the required fields for connection validation
        if Map.has_key?(provider_config, :id) or Map.has_key?(provider_config, "id") do
          # Convert string keys to atoms before validation
          normalized_config = normalize_keys_for_validation(provider_config)
          ReqLLM.Metadata.validate(:connection, normalized_config)
        else
          {:ok, provider_config}
        end

      _ ->
        {:ok, nil}
    end
  end

  # Validate models metadata within provider metadata
  defp validate_models_metadata(metadata) do
    models = Map.get(metadata, :models) || Map.get(metadata, "models") || []

    case models do
      [] ->
        {:ok, []}

      models_list when is_list(models_list) ->
        validate_each_model(models_list)

      _ ->
        {:error, "Models must be a list"}
    end
  end

  # Validate each model in the models list
  defp validate_each_model(models) do
    # Filter out invalid models rather than failing validation entirely
    valid_models =
      Enum.filter(models, fn model ->
        case validate_single_model(model) do
          {:ok, _} -> true
          {:error, _} -> false
        end
      end)

    {:ok, valid_models}
  end

  # Validate a single model's metadata
  defp validate_single_model(model) when is_map(model) do
    with {:ok, _} <- validate_model_capabilities(model),
         {:ok, _} <- validate_model_limits(model),
         {:ok, _} <- validate_model_costs(model) do
      {:ok, model}
    end
  end

  # Allow simple string models (for backward compatibility and tests)
  defp validate_single_model(model) when is_binary(model), do: {:ok, model}

  defp validate_single_model(_), do: {:error, "Model must be a map or string"}

  # Validate capabilities section of model metadata
  defp validate_model_capabilities(model) do
    case extract_model_section(model, ["capabilities", :capabilities]) do
      nil ->
        {:ok, nil}

      capabilities when is_map(capabilities) ->
        # Only validate if it looks like a proper capabilities structure
        if has_validation_keys?(capabilities, [:id]) do
          # Convert string keys to atoms before validation
          normalized_capabilities = normalize_keys_for_validation(capabilities)
          ReqLLM.Metadata.validate(:capabilities, normalized_capabilities)
        else
          {:ok, capabilities}
        end

      _ ->
        {:ok, nil}
    end
  end

  # Validate limits section of model metadata
  defp validate_model_limits(model) do
    case extract_model_section(model, ["limit", :limit, "limits", :limits]) do
      nil ->
        {:ok, nil}

      limits when is_map(limits) ->
        # Only validate if it looks like a proper limits structure
        if has_validation_keys?(limits, [:context]) do
          # Convert string keys to atoms before validation
          normalized_limits = normalize_keys_for_validation(limits)
          ReqLLM.Metadata.validate(:limits, normalized_limits)
        else
          {:ok, limits}
        end

      _ ->
        {:ok, nil}
    end
  end

  # Validate costs section of model metadata
  defp validate_model_costs(model) do
    case extract_model_section(model, ["cost", :cost, "costs", :costs]) do
      nil ->
        {:ok, nil}

      costs when is_map(costs) ->
        # Only validate if it looks like a proper costs structure
        if has_validation_keys?(costs, [:input, :output]) do
          # Convert string keys to atoms before validation
          normalized_costs = normalize_keys_for_validation(costs)
          ReqLLM.Metadata.validate(:costs, normalized_costs)
        else
          {:ok, costs}
        end

      _ ->
        {:ok, nil}
    end
  end

  # Helper to extract a section from model using multiple possible keys
  defp extract_model_section(model, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(model, key)
    end)
  end

  # Helper to check if a map has any of the expected validation keys
  defp has_validation_keys?(map, expected_keys) do
    Enum.any?(expected_keys, fn key ->
      Map.has_key?(map, key) or Map.has_key?(map, to_string(key))
    end)
  end

  # Helper to convert string keys to atoms for NimbleOptions validation
  defp normalize_keys_for_validation(data) when is_map(data) do
    data
    |> Map.new(fn
      {key, value} when is_binary(key) ->
        # Convert known string keys to atoms safely
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError ->
              # If atom doesn't exist, create it for common validation keys
              if key in ~w(id input output context capabilities reasoning tool_call modalities limit cost costs) do
                String.to_atom(key)
              else
                # Keep as string if not a known validation key
                key
              end
          end

        {atom_key, normalize_keys_for_validation(value)}

      {key, value} ->
        {key, normalize_keys_for_validation(value)}
    end)
  end

  defp normalize_keys_for_validation(data) when is_list(data) do
    Enum.map(data, &normalize_keys_for_validation/1)
  end

  defp normalize_keys_for_validation(data), do: data

  @doc """
  Gets the environment variable key for a provider's API authentication.

  Tries to get the key from provider metadata first, then falls back
  to the provider's `default_env_key/0` callback if implemented.

  ## Parameters

  - `provider_id` - Provider atom identifier (e.g., `:anthropic`)

  ## Returns

  The environment variable name string, or nil if not found.

  ## Examples

      iex> ReqLLM.Provider.Registry.get_env_key(:anthropic)
      "ANTHROPIC_API_KEY"

      iex> ReqLLM.Provider.Registry.get_env_key(:unknown)
      nil
  """
  @spec get_env_key(atom()) :: String.t() | nil
  def get_env_key(provider_id) when is_atom(provider_id) do
    # Try metadata first
    with {:ok, metadata} <- get_provider_metadata(provider_id),
         env_list when is_list(env_list) <-
           get_in(metadata, ["provider", "env"]) || get_in(metadata, [:provider, :env]),
         [env_var | _] when is_binary(env_var) <- env_list do
      env_var
    else
      _ -> try_provider_default_env_key(provider_id)
    end
  end

  defp try_provider_default_env_key(provider_id) do
    case get_provider(provider_id) do
      {:ok, provider_module} ->
        if function_exported?(provider_module, :default_env_key, 0) do
          try do
            provider_module.default_env_key()
          rescue
            _ -> nil
          end
        end

      _ ->
        nil
    end
  end
end
