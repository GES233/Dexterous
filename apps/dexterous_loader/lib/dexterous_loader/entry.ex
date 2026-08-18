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
end
