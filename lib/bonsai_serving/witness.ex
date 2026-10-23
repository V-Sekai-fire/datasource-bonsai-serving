defmodule BonsaiServing.Witness do
  @moduledoc """
  Ask the served model one temperature-0 question and hash the answer. This is how a change to the
  serving stack is judged: by the text it produces, not by the fact that it started.

  The API key is read from the environment, then `~/.hermes/.env`, then `/etc/ninfer/env` through
  sudo. A `/v1/models` body is never printed: ninfer-serve echoes its whole command line, `--api-key`
  included, so only the decoded id leaves this module.
  """
  alias BonsaiServing.{Config, Shell}

  @doc """
  The bearer token for the local server. The files are read first on purpose: a long-lived process
  (the agent gateway) holds a snapshot of its environment from before a key rotation, so an exported
  variable can be stale while the file on disk is current.
  """
  def api_key do
    case from_files() do
      {:ok, key} -> {:ok, key}
      {:error, _} -> from_env()
    end
  end

  defp from_env do
    case System.get_env("BONSAI_DESK_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end

  defp from_files do
    home = System.user_home() || ""
    candidates = [Path.join(home, ".hermes/.env"), Config.env_file()]

    Enum.reduce_while(candidates, {:error, :no_api_key}, fn path, _acc ->
      case read_env(path, ["BONSAI_DESK_API_KEY", "NINFER_API_KEY"]) do
        {:ok, key} -> {:halt, {:ok, key}}
        {:error, _} -> {:cont, {:error, :no_api_key}}
      end
    end)
  end

  defp read_env(path, vars) do
    text =
      case File.read(path) do
        {:ok, text} -> {:ok, text}
        {:error, _} -> Shell.sudo(["cat", path])
      end

    with {:ok, text} <- text,
         {:ok, key} <- parse_env(text, vars) do
      {:ok, key}
    end
  end

  @doc "Pure: find the first of `vars` in an env file's text."
  def parse_env(text, vars) do
    lines = String.split(text, "\n", trim: true)

    found =
      Enum.find_value(vars, fn var ->
        Enum.find_value(lines, fn line ->
          case String.split(line, "=", parts: 2) do
            [^var, value] -> String.trim(value)
            _ -> nil
          end
        end)
      end)

    case found do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :not_found}
    end
  end

  @doc "The served model's id, decoded from /v1/models without echoing the body."
  def model_id(port \\ nil, key \\ nil) do
    port = port || Config.port()

    with {:ok, key} <- maybe_key(key),
         {:ok, body} <- get("http://127.0.0.1:#{port}/v1/models", key),
         {:ok, json} <- decode(body),
         {:ok, id} <- first_model_id(json) do
      {:ok, id}
    end
  end

  defp maybe_key(nil), do: api_key()
  defp maybe_key(key), do: {:ok, key}

  defp first_model_id(%{"data" => [%{"id" => id} | _]}), do: {:ok, id}
  defp first_model_id(_), do: {:error, :no_model_in_list}

  @doc "One temperature-0 completion: the text, its length and its sha256."
  def ask(prompt \\ nil, opts \\ []) do
    prompt = prompt || Config.witness_prompt()

    with {:ok, %{text: text}} <- chat([%{role: "user", content: prompt}], opts) do
      {:ok, %{text: text, chars: String.length(text), sha256: sha256(text)}}
    end
  end

  @doc """
  One temperature-0 chat over a whole message list. Returns the reply text, the completion token
  count the server reported, and the client wall time in milliseconds.

  Options: `:port`, `:max_tokens` (default 200), `:key` and `:model` (looked up once per call when
  absent; a caller sending many requests passes both so each request is one round trip).
  """
  def chat(messages, opts \\ []) do
    port = Keyword.get(opts, :port, Config.port())
    max_tokens = Keyword.get(opts, :max_tokens, 200)

    with {:ok, key} <- maybe_key(Keyword.get(opts, :key)),
         {:ok, model} <- maybe_model(Keyword.get(opts, :model), port, key) do
      started = System.monotonic_time(:microsecond)

      with {:ok, body} <- post("http://127.0.0.1:#{port}/v1/chat/completions", key, %{
             model: model,
             messages: messages,
             temperature: 0,
             max_tokens: max_tokens,
             stream: false
           }),
           {:ok, json} <- decode(body),
           {:ok, text} <- first_content(json) do
        wall_ms = (System.monotonic_time(:microsecond) - started) / 1000

        {:ok, %{text: text, completion_tokens: completion_tokens(json), wall_ms: wall_ms}}
      end
    end
  end

  @doc "The key and model id once, for a caller that sends many requests."
  def session(port \\ Config.port()) do
    with {:ok, key} <- api_key(),
         {:ok, model} <- model_id(port, key) do
      {:ok, [key: key, model: model, port: port]}
    end
  end

  defp maybe_model(nil, port, key), do: model_id(port, key)
  defp maybe_model(model, _port, _key), do: {:ok, model}

  defp completion_tokens(%{"usage" => %{"completion_tokens" => n}}) when is_integer(n), do: n
  defp completion_tokens(_), do: 0

  defp first_content(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content),
       do: {:ok, content}

  defp first_content(%{"error" => %{"message" => message}}), do: {:error, {:server_error, message}}
  defp first_content(_), do: {:error, :no_choices}

  @doc "Ask the witness question and compare the answer with the expected hash."
  def verify(opts \\ []) do
    expected = Keyword.get(opts, :expected, Config.witness_sha())

    with {:ok, %{sha256: sha} = answer} <- ask(nil, opts) do
      if sha == expected do
        {:ok, Map.put(answer, :verdict, :match)}
      else
        {:error, {:mismatch, expected, sha, answer}}
      end
    end
  end

  def sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  # ---------------------------------------------------------------- HTTP
  defp get(url, key) do
    :inets.start()
    :ssl.start()

    request = {String.to_charlist(url), auth_headers(key)}

    case :httpc.request(:get, request, [timeout: 60_000], []) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, IO.iodata_to_binary(body)}
      {:ok, {{_, status, _}, _headers, _body}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, {:http, reason}}
    end
  end

  defp post(url, key, payload) do
    :inets.start()
    :ssl.start()

    # `connection: close` gives every request its own socket. Without it :httpc queues a request
    # behind another on a kept-alive session to the same host, so k "parallel" callers arrive one at
    # a time and a concurrency or blocking measurement reads the client, not the server.
    headers =
      auth_headers(key) ++
        [{~c"content-type", ~c"application/json"}, {~c"connection", ~c"close"}]
    request = {String.to_charlist(url), headers, ~c"application/json", :json.encode(payload)}

    case :httpc.request(:post, request, [timeout: 900_000], []) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, IO.iodata_to_binary(body)}
      {:ok, {{_, status, _}, _headers, body}} -> {:error, {:http, status, safe(body)}}
      {:error, reason} -> {:error, {:http, reason}}
    end
  end

  # An error body can carry the command line back, so keep only its first line and its size.
  defp safe(body) do
    text = IO.iodata_to_binary(body)
    %{bytes: byte_size(text), first_line: text |> String.split("\n") |> List.first() |> String.slice(0, 120)}
  end

  defp auth_headers(""), do: []
  defp auth_headers(nil), do: []
  defp auth_headers(key), do: [{~c"authorization", String.to_charlist("Bearer " <> key)}]

  defp decode(body) do
    # :json.decode/1 raises on a malformed body and there is no non-raising variant in OTP, so the
    # body is only decoded when the server said 200: a 200 that is not JSON is a server defect, and
    # this workspace lets that crash rather than wrapping it in a try. Expected failures (a non-200,
    # a refused connection) never reach here.
    case :json.decode(body) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, :not_json}
    end
  end
end
