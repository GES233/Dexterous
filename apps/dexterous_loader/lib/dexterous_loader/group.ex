defmodule DexterousLoader.Group do
  @moduledoc """
  A component that loads a list of child entries as a subgroup (the paper's
  `@cordisjs/group`).

  It is an ordinary component resting on the core's registration primitive:
  children are instantiated with `Dexterous.Context.use/3`, so unloading the
  group cascades to them. When the group's config changes, the group fiber
  reloads and the subtree is rebuilt; per-child diffing is left to a future
  refinement.
  """

  use Dexterous.Component

  alias DexterousLoader.Entry

  @impl true
  def apply(ctx, entries) do
    Enum.each(entries, fn
      %Entry{disabled: true} -> :skip
      %Entry{} = entry -> DexterousLoader.spawn_entry(ctx, entry)
    end)
  end
end
