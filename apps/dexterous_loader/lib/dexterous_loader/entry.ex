defmodule DexterousLoader.Entry do
  @moduledoc """
  A declarative configuration entry: the authoritative record of one fiber
  (paper Section 5.2.1, Definition 74).

    * `:id` — stable identifier, the reconciliation key
    * `:component` — the component module to instantiate (the paper's `url`)
    * `:config` — configuration bound into the component's effect function
    * `:disabled` — administratively turned off
    * `:isolate` — realm annotations, `%{key => true | String.t()}`:
      `true` asks for a realm private to this entry (tagged by its id), a
      string names a global realm shared by every entry naming it; see
      `DexterousLoader.Isolate`
    * `:intercept` — interception annotations, `%{key => metadata}`

  When reconciliation sees only the `:isolate` field change, the entry's
  realms are reassigned in place (paper Algorithm 7, `DexterousLoader.Isolate`)
  instead of rebuilding the fiber.
  """

  @enforce_keys [:id, :component]
  defstruct [:id, :component, config: nil, disabled: false, isolate: %{}, intercept: %{}]

  @type t :: %__MODULE__{
          id: term(),
          component: module(),
          config: term(),
          disabled: boolean(),
          isolate: %{Dexterous.Context.key() => true | String.t()},
          intercept: %{Dexterous.Context.key() => map()}
        }

  @doc """
  Encode an entry as a JSON-safe map (the on-disk form of the authoritative
  record, paper Section 5.2.1). Atoms are tagged (`%{"__atom__" => "..."}`)
  so they round-trip exactly; binaries stay plain JSON strings. `:isolate`
  and `:intercept` encode as lists of `key`/`value` pairs, since JSON object
  keys cannot carry the atom tag. Restrictions: `:config` and interception
  metadata must be JSON-encodable terms (no functions, pids or references —
  so `:transform` interceptors cannot be persisted).
  """
  def to_map(%__MODULE__{} = entry) do
    %{
      "id" => encode_term(entry.id),
      "component" => Atom.to_string(entry.component),
      "config" => entry.config,
      "disabled" => entry.disabled,
      "isolate" => encode_annotations(entry.isolate),
      "intercept" => encode_annotations(entry.intercept)
    }
  end

  @doc """
  Decode an entry from its JSON map form (see `to_map/1`). Atoms — module
  names, tagged ids and keys — are resolved with `String.to_existing_atom/1`:
  they must already be loaded (decoding never creates atoms), and an unknown
  atom raises `ArgumentError`.
  """
  def from_map(%{} = map) do
    %__MODULE__{
      id: decode_term(Map.fetch!(map, "id")),
      component: Map.fetch!(map, "component") |> String.to_existing_atom(),
      config: Map.get(map, "config"),
      disabled: Map.get(map, "disabled", false),
      isolate: decode_annotations(Map.get(map, "isolate", [])),
      intercept: decode_annotations(Map.get(map, "intercept", []))
    }
  end

  defp encode_annotations(annotations) do
    Enum.map(annotations, fn {key, value} -> %{"key" => encode_term(key), "value" => value} end)
  end

  defp decode_annotations(pairs) do
    Map.new(pairs, fn %{"key" => key, "value" => value} -> {decode_term(key), value} end)
  end

  defp encode_term(term) when is_atom(term), do: %{"__atom__" => Atom.to_string(term)}
  defp encode_term(term) when is_binary(term), do: term

  defp decode_term(%{"__atom__" => atom}) do
    String.to_existing_atom(atom)
  rescue
    ArgumentError ->
      reraise ArgumentError,
              [message: "unknown atom #{inspect(atom)} in a persisted entry (atoms are never created on decode)"],
              __STACKTRACE__
  end

  defp decode_term(term) when is_binary(term), do: term
end
