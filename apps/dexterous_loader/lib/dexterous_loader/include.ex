defmodule DexterousLoader.Include do
  @moduledoc """
  A component that loads entries from an external JSON configuration file
  and grafts them in as a nested subtree (the paper's `@cordisjs/include`,
  Section 5.2.1).

  The config is the file path (a binary). The file holds a JSON array of
  entries in the form `DexterousLoader.Entry.to_map/1` produces; read it back
  with `DexterousLoader.load_entries/1` or write it with
  `DexterousLoader.write_entries/2`.

  Like `DexterousLoader.Group`, this is an ordinary component resting on the
  registration primitive: children are instantiated with
  `Dexterous.Context.use/3`, so unloading cascades, and a same-path config
  change re-reads the file and applies a keyed diff over child ids. A path
  change reloads the component. A file that fails to read or parse fails the
  fiber (`:failed` with the reason), leaving the last good subtree recovered
  — reconcile again once the file is fixed.

  The file is read on (re)load and on config changes; edits to the file do
  not propagate by themselves — reconcile or reload the entry to pick them
  up.
  """

  use Dexterous.Component

  alias Dexterous.Context

  @impl true
  def apply(%Context{} = ctx, path) when is_binary(path) do
    {:ok, entries} = DexterousLoader.load_entries(path)
    DexterousLoader.Group.apply(ctx, entries)
  end

  @impl true
  def update(%Context{} = ctx, old_path, new_path) do
    if old_path == new_path do
      {:ok, entries} = DexterousLoader.load_entries(new_path)
      DexterousLoader.Group.update(ctx, [], entries)
    else
      :reload
    end
  end
end
