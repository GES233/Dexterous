defmodule DexterousLoader.IncludeTest do
  use ExUnit.Case, async: false

  alias Dexterous.Store
  alias DexterousLoader.Entry

  defmodule JsonProbe do
    @moduledoc "Reports its JSON-decoded label to the test pid stashed in :persistent_term."
    use Dexterous.Component

    @impl true
    def apply(_ctx, config) do
      test = :persistent_term.get({__MODULE__, :test})
      send(test, {:json_probe_applied, config["label"]})
    end
  end

  setup do
    :persistent_term.put({JsonProbe, :test}, self())

    for {_, pid, _, _} <- DynamicSupervisor.which_children(Dexterous.FiberSup) do
      DynamicSupervisor.terminate_child(Dexterous.FiberSup, pid)
    end

    Store.reset(node())

    path = Path.join(System.tmp_dir!(), "dexterous_include_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)

    {:ok, path: path}
  end

  defp entry(id, label) do
    %Entry{id: id, component: JsonProbe, config: %{"label" => label}}
  end

  test "write_entries/load_entries round-trips a configuration", %{path: path} do
    entries = [
      entry(:a, "x"),
      %Entry{
        id: :b,
        component: JsonProbe,
        config: %{"label" => "y"},
        disabled: true,
        isolate: %{shared: "room"}
      }
    ]

    assert :ok = DexterousLoader.write_entries(path, entries)
    assert {:ok, decoded} = DexterousLoader.load_entries(path)

    assert [%Entry{id: :a, component: JsonProbe, config: %{"label" => "x"}} | _] = decoded
    assert Enum.at(decoded, 1).disabled == true
    assert Enum.at(decoded, 1).isolate == %{shared: "room"}
  end

  test "binary ids and keys round-trip as binaries, atoms as atoms", %{path: path} do
    entries = [
      %Entry{
        id: "binary-id",
        component: JsonProbe,
        config: %{"label" => "x"},
        isolate: %{"binary_key" => "room"},
        intercept: %{"binary_key" => %{"note" => "hi"}}
      },
      %Entry{id: :atom_id, component: JsonProbe, config: %{"label" => "y"}, isolate: %{atom_key: "room"}}
    ]

    assert :ok = DexterousLoader.write_entries(path, entries)
    assert {:ok, [first, second]} = DexterousLoader.load_entries(path)

    # No atom/binary confusion either way.
    assert first.id == "binary-id"
    assert first.isolate == %{"binary_key" => "room"}
    assert first.intercept == %{"binary_key" => %{"note" => "hi"}}
    assert second.id == :atom_id
    assert second.isolate == %{atom_key: "room"}
  end

  test "Include grafts the file's entries as a nested subtree", %{path: path} do
    :ok = DexterousLoader.write_entries(path, [entry(:c1, "a")])

    ctx = Dexterous.root()
    {:ok, loader} = DexterousLoader.start_link(ctx, [%Entry{id: :inc, component: DexterousLoader.Include, config: path}])

    assert_receive {:json_probe_applied, "a"}

    # Editing the file does not propagate by itself; reloading the entry
    # picks the new file up.
    :ok = DexterousLoader.write_entries(path, [entry(:c1, "b"), entry(:c2, "c")])
    :ok = DexterousLoader.reload_entry(loader, :inc)

    assert_receive {:json_probe_applied, "b"}
    assert_receive {:json_probe_applied, "c"}
  end

  test "Include fails the fiber on an unreadable file", %{path: path} do
    ctx = Dexterous.root()
    missing = path <> ".missing"

    {:ok, loader} =
      DexterousLoader.start_link(ctx, [%Entry{id: :inc, component: DexterousLoader.Include, config: missing}])

    pid = DexterousLoader.fibers(loader)[:inc].pid

    assert eventually(fn ->
             status = Dexterous.Fiber.status(pid)
             if status.state == :failed, do: status
           end)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: nil

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end
end
