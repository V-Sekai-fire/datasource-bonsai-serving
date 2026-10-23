defmodule BonsaiServing.Devices do
  @moduledoc """
  The card pins. Devices are named by GPU UUID, never by index: the order of the UUIDs in
  CUDA_VISIBLE_DEVICES is the CUDA ordinal order, while nvidia-smi's indices and CUDA_DEVICE_ORDER
  are separate opinions. A UUID that is not present is an error, never a fallback.
  """
  alias BonsaiServing.{Config, Shell}

  @type pins :: %{primary: String.t(), secondary: String.t()}

  @doc "Read the pins file. Missing or unreadable is an error, not an empty map."
  def pins do
    case Shell.sudo(["cat", Config.devices_file()]) do
      {:ok, text} -> parse(text)
      {:error, reason} -> {:error, {:no_pins, reason}}
    end
  end

  @doc "Pure: `primary=GPU-...\\nsecondary=GPU-...` to a map."
  def parse(text) do
    pairs =
      text
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.flat_map(fn line ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> [{String.trim(k), String.trim(v)}]
          _ -> []
        end
      end)

    case {Map.new(pairs)["primary"], Map.new(pairs)["secondary"]} do
      {p, s} when is_binary(p) and is_binary(s) and p != "" and s != "" ->
        {:ok, %{primary: p, secondary: s}}

      _ ->
        {:error, {:incomplete_pins, pairs}}
    end
  end

  @doc "Every card present, straight from the driver."
  def cards do
    case Shell.run(["nvidia-smi", "--query-gpu=index,uuid,name,memory.total", "--format=csv,noheader"]) do
      {:ok, csv} -> {:ok, parse_cards(csv)}
      {:error, reason} -> {:error, {:nvidia_smi, reason}}
    end
  end

  @doc "Pure: the CSV above to a list of maps."
  def parse_cards(csv) do
    csv
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case line |> String.split(",") |> Enum.map(&String.trim/1) do
        [index, uuid, name, memory] ->
          [%{index: String.to_integer(index), uuid: uuid, name: name, memory: memory}]

        _ ->
          []
      end
    end)
  end

  @doc "The pins, checked against the cards actually present, with their names."
  def resolve do
    with {:ok, pins} <- pins(),
         {:ok, cards} <- cards(),
         {:ok, primary} <- find_card(cards, pins.primary, "primary"),
         {:ok, secondary} <- find_card(cards, pins.secondary, "secondary") do
      {:ok, Map.put(pins, :cards, %{primary: primary, secondary: secondary})}
    end
  end

  defp find_card(cards, uuid, label) do
    case Enum.find(cards, &(&1.uuid == uuid)) do
      nil ->
        present = Enum.map_join(cards, ", ", & &1.uuid)
        {:error, {:card_missing, label, uuid, present}}

      card ->
        {:ok, card}
    end
  end
end
