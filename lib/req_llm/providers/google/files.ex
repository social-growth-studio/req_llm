defmodule ReqLLM.Providers.Google.Files do
  @moduledoc """
  Google Gemini File API capability.

  Provides file upload functionality for Google Gemini models. Files are uploaded
  to Google's File API and can be referenced in messages using file URIs.

  ## Usage

      # Upload a file
      {:ok, file_uri} = ReqLLM.Providers.Google.Files.upload(
        audio_data,
        "audio/mp3",
        "podcast.mp3"
      )

      # Use in a message
      context = ReqLLM.Context.new([
        ReqLLM.Context.user([
          ReqLLM.Message.ContentPart.text("Describe this audio"),
          ReqLLM.Message.ContentPart.file_uri(file_uri, "audio/mp3")
        ])
      ])

      {:ok, response} = ReqLLM.generate_text("google:gemini-2.0-flash", context)

  ## Authentication

  Uses the same authentication as the Google provider:
  - `:api_key` option (highest priority)
  - `Application.get_env(:req_llm, :google_api_key)`
  - `GOOGLE_API_KEY` environment variable

  ## API Reference

  See Google's File API documentation:
  https://ai.google.dev/gemini-api/docs/file-upload
  """

  @behaviour ReqLLM.Provider.Capability

  @impl true
  def capability_name, do: :files

  @impl true
  def supported_operations, do: [:upload, :delete, :get, :list, :wait_active]

  @doc """
  Upload a file to Google's File API for use with Gemini models.

  Uses the resumable upload protocol to upload files. Returns the file URI
  that can be used with `ReqLLM.Message.ContentPart.file_uri/2`.

  ## Parameters

    * `file_data` - Binary data of the file to upload
    * `mime_type` - MIME type of the file (e.g., "audio/mp3", "video/mp4", "application/pdf")
    * `display_name` - Display name for the file in the API
    * `opts` - Options:
      - `:api_key` - API key (optional, uses ReqLLM.Keys.get!/2 by default)
      - `:base_url` - Base URL (optional, uses provider default)

  ## Returns

    * `{:ok, file_uri}` - On success, returns the file URI
    * `{:error, reason}` - On failure

  ## Examples

      {:ok, file_uri} = ReqLLM.Providers.Google.Files.upload(
        audio_data,
        "audio/mp3",
        "podcast.mp3"
      )

      # With explicit API key
      {:ok, file_uri} = ReqLLM.Providers.Google.Files.upload(
        audio_data,
        "audio/mp3",
        "podcast.mp3",
        api_key: "AIza..."
      )
  """
  @spec upload(binary(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def upload(file_data, mime_type, display_name, opts \\ []) when is_binary(file_data) do
    api_key = ReqLLM.Keys.get!(:google, opts)
    base_url = Keyword.get(opts, :base_url, ReqLLM.Providers.Google.default_base_url())
    num_bytes = byte_size(file_data)
    wait_for_active = Keyword.get(opts, :wait_for_active, true)

    with {:ok, upload_url} <-
           initiate_resumable_upload(base_url, api_key, num_bytes, mime_type, display_name),
         {:ok, file_info} <- upload_file_bytes(upload_url, file_data, num_bytes),
         {:ok, file_uri} <- extract_file_uri(file_info),
         :ok <- maybe_wait_for_active(file_uri, wait_for_active, api_key, base_url) do
      {:ok, file_uri}
    end
  end

  defp initiate_resumable_upload(base_url, api_key, num_bytes, mime_type, display_name) do
    upload_base_url = base_url |> String.replace("/v1beta", "")
    url = "#{upload_base_url}/upload/v1beta/files"

    headers = [
      {"x-goog-api-key", api_key},
      {"X-Goog-Upload-Protocol", "resumable"},
      {"X-Goog-Upload-Command", "start"},
      {"X-Goog-Upload-Header-Content-Length", to_string(num_bytes)},
      {"X-Goog-Upload-Header-Content-Type", mime_type},
      {"Content-Type", "application/json"}
    ]

    body = Jason.encode!(%{file: %{display_name: display_name}})

    case Req.post(url, headers: headers, body: body) do
      {:ok, %{status: status, headers: response_headers}} when status in 200..299 ->
        extract_upload_url(response_headers)

      {:ok, %{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "Upload initiation failed",
           status: status,
           response_body: body
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_file_bytes(upload_url, file_data, num_bytes) do
    headers = [
      {"Content-Length", to_string(num_bytes)},
      {"X-Goog-Upload-Offset", "0"},
      {"X-Goog-Upload-Command", "upload, finalize"}
    ]

    case Req.post(upload_url, headers: headers, body: file_data) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "File upload failed",
           status: status,
           response_body: body
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_upload_url(headers) do
    headers
    |> Enum.find(fn {key, _} -> String.downcase(key) == "x-goog-upload-url" end)
    |> case do
      {_, url} when is_binary(url) ->
        {:ok, String.trim(url)}

      {_, [url | _]} when is_binary(url) ->
        {:ok, String.trim(url)}

      nil ->
        {:error, ReqLLM.Error.API.Response.exception(reason: "No upload URL in response headers")}
    end
  end

  defp extract_file_uri(%{"file" => %{"uri" => uri}}), do: {:ok, uri}

  defp extract_file_uri(other) do
    {:error,
     ReqLLM.Error.API.Response.exception(
       reason: "No file URI in response",
       response_body: other
     )}
  end

  @doc """
  Delete a file from Google's File API.

  ## Parameters

    * `file_uri` - The file URI returned from `upload/4` (e.g., "https://generativelanguage.googleapis.com/v1beta/files/abc123")
    * `opts` - Options:
      - `:api_key` - API key (optional, uses ReqLLM.Keys.get!/2 by default)
      - `:base_url` - Base URL (optional, uses provider default)

  ## Returns

    * `:ok` - On success
    * `{:error, reason}` - On failure

  ## Examples

      {:ok, file_uri} = ReqLLM.Providers.Google.Files.upload(data, "audio/mp3", "audio.mp3")
      
      # Use the file...
      
      # Clean up
      :ok = ReqLLM.Providers.Google.Files.delete(file_uri)
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(file_uri, opts \\ []) when is_binary(file_uri) do
    api_key = ReqLLM.Keys.get!(:google, opts)
    base_url = Keyword.get(opts, :base_url, ReqLLM.Providers.Google.default_base_url())

    file_name = extract_file_name(file_uri)

    case Req.delete("#{base_url}/files/#{file_name}", headers: [{"x-goog-api-key", api_key}]) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "File deletion failed",
           status: status,
           response_body: body
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_file_name(file_uri) do
    file_uri |> String.split("/") |> List.last()
  end

  defp maybe_wait_for_active(_file_uri, false, _api_key, _base_url), do: :ok

  defp maybe_wait_for_active(file_uri, true, api_key, base_url) do
    wait_for_active(file_uri, api_key, base_url)
  end

  @doc """
  Wait for an uploaded file to become ACTIVE.

  Google's File API processes files asynchronously. This function polls
  the file status until it becomes ACTIVE or fails.

  ## Parameters

    * `file_uri` - The file URI returned from `upload/4`
    * `opts` - Options:
      - `:api_key` - API key (optional, uses ReqLLM.Keys.get!/2 by default)
      - `:base_url` - Base URL (optional, uses provider default)
      - `:max_attempts` - Maximum polling attempts (default: 30)
      - `:poll_interval` - Milliseconds between polls (default: 1000)

  ## Returns

    * `:ok` - File is ACTIVE
    * `{:error, reason}` - File failed to become active or polling timed out
  """
  @spec wait_for_active(String.t(), keyword()) :: :ok | {:error, term()}
  def wait_for_active(file_uri, opts \\ []) when is_binary(file_uri) do
    api_key = ReqLLM.Keys.get!(:google, opts)
    base_url = Keyword.get(opts, :base_url, ReqLLM.Providers.Google.default_base_url())
    wait_for_active(file_uri, api_key, base_url, opts)
  end

  defp wait_for_active(file_uri, api_key, base_url, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 30)
    poll_interval = Keyword.get(opts, :poll_interval, 1000)

    file_name = extract_file_name(file_uri)

    poll_file_status(file_name, api_key, base_url, max_attempts, poll_interval, 0)
  end

  defp poll_file_status(file_name, api_key, base_url, max_attempts, poll_interval, attempt) do
    if attempt >= max_attempts do
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "File did not become ACTIVE within #{max_attempts} attempts"
       )}
    else
      case Req.get("#{base_url}/files/#{file_name}", headers: [{"x-goog-api-key", api_key}]) do
        {:ok, %{status: 200, body: %{"state" => "ACTIVE"}}} ->
          :ok

        {:ok, %{status: 200, body: %{"state" => "PROCESSING"}}} ->
          Process.sleep(poll_interval)
          poll_file_status(file_name, api_key, base_url, max_attempts, poll_interval, attempt + 1)

        {:ok, %{status: 200, body: %{"state" => state}}} ->
          {:error,
           ReqLLM.Error.API.Request.exception(reason: "File entered unexpected state: #{state}")}

        {:ok, %{status: status, body: body}} ->
          {:error,
           ReqLLM.Error.API.Request.exception(
             reason: "Failed to get file status",
             status: status,
             response_body: body
           )}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
