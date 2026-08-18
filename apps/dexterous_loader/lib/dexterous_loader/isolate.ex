defmodule DexterousLoader.Isolate do
  @moduledoc """
  Managed realms and isolation realm reassignment (paper Section 5.2.1,
  Algorithm 7).

  The loader derives realms from an entry's `:isolate` annotations
  deterministically, so a realm's identity survives the entry being rebuilt
  or moved between groups:

    * `true` selects a *local* realm `{:local, entry_id, key}` — private to
      the entry, tagged by its id, carried wherever the entry moves;
    * a string selects a *global* realm `{:global, label, key}` — shared by
      every entry naming that label. Being a pure term, an unreferenced
      realm needs no garbage collection: its bindings disappear with the
      fibers that installed them.

  When reconciliation sees an entry whose `isolate` field changed,
  `patch/4` reassigns its realms instead of rebuilding the fiber:

    1. a fresh *delimiter tag* (`δ_k`) is drawn per changed key and stored on
       the entry's fiber; tags resolve down the fiber parent chain
       (`Dexterous.Store.delimiter_for/3`), so a provider's tag equals the
       fresh tag exactly when the binding is the entry's own;
    2. the fiber adopts the new realm map and reloads in place
       (`Dexterous.Fiber.patch_isolate/3`), keeping its identity;
    3. each owned binding moves from the old realm to the new one
       (`Dexterous.Store.move/3`), so dependents that follow the move never
       see it disappear;
    4. dependents are notified with the algorithm's custom `affected`
       predicate in place of the plain realm test: a fiber matters exactly
       when it resolves the key in one of the two realms and the delimiter
       walk separates it from the entry's scope.

  The paper's delimiter is written on the entry's context and inherited by
  prototype chaining; here contexts are immutable struct copies, so tags
  live on fiber attributes in the store and inheritance is the parent-chain
  walk. The two agree because every fiber in an entry's subtree descends
  from the entry's fiber.
  """

  alias Dexterous.{Context, Fiber, Store}
  alias DexterousLoader.Entry

  @doc """
  The realm an `:isolate` annotation selects for `key`: `true` gives a
  local realm tagged by the entry's id; a string names a global realm shared
  by every entry naming it.
  """
  def realm_for(%Entry{id: id}, key, true), do: {:local, id, key}
  def realm_for(%Entry{}, key, label) when is_binary(label), do: {:global, label, key}

  @doc "The full realm map an entry's annotations produce over the parent's."
  def isolate_map(%Entry{} = entry, parent_isolate) do
    annotations =
      Map.new(entry.isolate, fn {key, annotation} ->
        {key, realm_for(entry, key, annotation)}
      end)

    Map.merge(parent_isolate, annotations)
  end

  @doc """
  Reassign the realms of the entry running as fiber `pid` to what
  `new_entry` declares (Algorithm 7). The fiber keeps its identity, adopts
  the new realm map and config, and reloads; bindings it owns move along.

  `parent_ctx` supplies the *new* parent's realm map and interception
  metadata: for an in-place isolate change it is the context the entry was
  spawned on; for a move (`DexterousLoader.move/3`) it carries the target
  parent's maps. Options:

    * `:intercept` — replace the fiber's interception metadata (used when a
      move changes what the entry inherits).
  """
  def patch(parent_ctx, pid, new_entry), do: patch(parent_ctx, pid, new_entry, [])

  def patch(%Context{} = parent_ctx, pid, %Entry{} = new_entry, opts) do
    scope = parent_ctx.scope
    fiber_id = Fiber.status(pid).id
    intercept = Keyword.get(opts, :intercept)

    with {:ok, attrs} <- Store.get_fiber(scope, fiber_id) do
      old_map = attrs.isolate
      new_map = isolate_map(new_entry, parent_ctx.isolate)

      delta =
        (Map.keys(old_map) ++ Map.keys(new_map))
        |> Enum.uniq()
        |> Enum.filter(fn key -> Map.get(old_map, key, key) != Map.get(new_map, key, key) end)

      repatch? = delta != [] or (not is_nil(intercept) and intercept != Map.get(attrs, :intercept))

      if not is_nil(intercept) do
        Store.update_fiber(scope, fiber_id, %{intercept: intercept})
      end

      Store.update_fiber(scope, fiber_id, %{entry: new_entry})

      if repatch? do
        # Step 1: fresh delimiter tags for the changed keys, written before
        # the diff reads the providers' tags — a provider inside the entry's
        # scope then resolves to the fresh tag, marking the binding as own.
        old_delims = Map.get(attrs, :delimiters, %{})
        fresh = Map.new(delta, fn key -> {key, make_ref()} end)
        transient = Map.merge(old_delims, fresh)

        Store.update_fiber(scope, fiber_id, %{isolate: new_map, delimiters: transient})

        # Step 2: the per-key service diff {old realm, new realm, entry tag,
        # provider tag}, taken against the old realm first; when the binding
        # there is own, the new realm's provider (if any) decides instead.
        diff =
          Map.new(delta, fn key ->
            {key, service_diff(scope, key, old_map, new_map, fresh[key])}
          end)

        # Step 3: the fiber adopts the new realms and reloads in place.
        Fiber.patch_isolate(pid, new_map, new_entry.config, intercept)

        # Step 4: move each binding that is the entry's own, provided the new
        # realm is not already occupied.
        for {key, {s1, s2, d1, d2}} <- diff,
            d1 == d2,
            match?({:ok, _}, Store.lookup(scope, s1)),
            Store.lookup(scope, s2) == :error do
          Store.move(scope, s1, s2)
          key
        end

        # Step 5: notify exactly the dependents the reassignment reaches.
        Context.notify(parent_ctx, Map.keys(diff),
          affected: fn {fid, fiber}, key ->
            case diff do
              %{^key => {s1, s2, d1, d2}} ->
                realm = Map.get(fiber.isolate, key, key)

                (realm == s1 or realm == s2) and
                  (Store.delimiter_for(scope, fid, key) == d1) != (d2 == d1)

              _ ->
                false
            end
          end
        )

        # Step 6: drop delimiter tags of keys the entry no longer isolates.
        Store.update_fiber(scope, fiber_id, %{
          delimiters: Map.take(transient, Map.keys(new_entry.isolate))
        })
      end
    end

    :ok
  end

  # {old realm, new realm, entry tag, provider tag} for one changed key.
  # The old realm's provider answers "is the binding the entry's own?"; when
  # it is, the new realm's provider (if any) overrides, since an occupied new
  # realm blocks the move and decides whom to notify.
  defp service_diff(scope, key, old_map, new_map, d1) do
    s1 = Map.get(old_map, key, key)
    s2 = Map.get(new_map, key, key)

    Enum.reduce_while([s1, s2], nil, fn realm, acc ->
      case Store.lookup(scope, realm) do
        {:ok, %{provider: provider}} when not is_nil(provider) ->
          tag = Store.delimiter_for(scope, provider, key)
          diff = {s1, s2, d1, tag}
          if tag == d1, do: {:cont, diff}, else: {:halt, diff}

        _no_binding_or_root_binding ->
          {:cont, acc}
      end
    end)
  end
end
