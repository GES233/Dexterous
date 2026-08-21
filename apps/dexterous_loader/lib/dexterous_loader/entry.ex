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
  Encode an entry as a JSON-safe map with string keys (the on-disk form of
  the authoritative record, paper Section 5.2.1). Restrictions: `:id`,
  `:isolate` and `:intercept` keys must be atoms or binaries; `:config` and
  interception metadata must be JSON-encodable terms (no functions, pids or
  references — so `:transform` interceptors cannot be persisted).
  """
  def to_map(%__MODULE__{} = entry) do
    %{
      "id" => encode_term(entry.id),
      "component" => Atom.to_string(entry.component),
      "config" => entry.config,
      "disabled" => entry.disabled,
      "isolate" => Map.new(entry.isolate, fn {k, v} -> {encode_term(k), v} end),
      "intercept" => Map.new(entry.intercept, fn {k, v} -> {encode_term(k), v} end)
    }
  end

  @doc """
  Decode an entry from its JSON map form (see `to_map/1`). Components are
  resolved with `String.to_existing_atom/1` — the module must already be
  loaded. Atom-looking ids and keys decode back to existing atoms, falling
  back to binaries.
  """
  def from_map(%{} = map) do
    %__MODULE__{
      id: decode_term(Map.fetch!(map, "id")),
      component: Map.fetch!(map, "component") |> String.to_existing_atom(),
      config: Map.get(map, "config"),
      disabled: Map.get(map, "disabled", false),
      isolate: Map.new(Map.get(map, "isolate", %{}), fn {k, v} -> {decode_term(k), v} end),
      intercept: Map.new(Map.get(map, "intercept", %{}), fn {k, v} -> {decode_term(k), v} end)
    }
  end

  defp encode_term(term) when is_atom(term), do: Atom.to_string(term)
  defp encode_term(term) when is_binary(term), do: term

  defp decode_term(term) when is_binary(term) do
    String.to_existing_atom(term)
  rescue
    ArgumentError -> term
  end
end
