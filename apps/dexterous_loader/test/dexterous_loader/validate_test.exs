defmodule DexterousLoader.ValidateTest do
  use ExUnit.Case, async: true

  alias DexterousLoader.Entry

  defmodule ProviderA do
    @moduledoc false
    use Dexterous.Component, inject: [:key_b], provide: [:key_a]
    @impl true
    def apply(_ctx, _config), do: :ok
  end

  defmodule ProviderB do
    @moduledoc false
    use Dexterous.Component, inject: [:key_a], provide: [:key_b]
    @impl true
    def apply(_ctx, _config), do: :ok
  end

  defmodule PlainProvider do
    @moduledoc false
    use Dexterous.Component, provide: [:shared]
    @impl true
    def apply(_ctx, _config), do: :ok
  end

  defmodule PlainConsumer do
    @moduledoc false
    use Dexterous.Component, inject: [:shared]
    @impl true
    def apply(_ctx, _config), do: :ok
  end

  test "a provider/consumer pair is clean" do
    entries = [
      %Entry{id: :p, component: PlainProvider},
      %Entry{id: :c, component: PlainConsumer}
    ]

    assert :ok = DexterousLoader.validate(entries)
  end

  test "a mutual dependency is reported as a cycle" do
    entries = [
      %Entry{id: :a, component: ProviderA},
      %Entry{id: :b, component: ProviderB}
    ]

    assert {:error, issues} = DexterousLoader.validate(entries)
    assert {:cycle, cycle} = List.keyfind(issues, :cycle, 0)
    assert Enum.sort(cycle) == [:a, :b]
  end

  test "two entries providing the same key in the same realm are reported" do
    entries = [
      %Entry{id: :p1, component: PlainProvider},
      %Entry{id: :p2, component: PlainProvider}
    ]

    assert {:error, [{:duplicate_provision, :shared, :shared, ids}]} =
             DexterousLoader.validate(entries)

    assert Enum.sort(ids) == [:p1, :p2]
  end

  test "the same key provided in distinct realms is not a duplicate" do
    entries = [
      %Entry{id: :p1, component: PlainProvider, isolate: %{shared: "room1"}},
      %Entry{id: :p2, component: PlainProvider, isolate: %{shared: "room2"}}
    ]

    assert :ok = DexterousLoader.validate(entries)
  end

  test "declarations inside groups are checked with the group's realms" do
    group = %Entry{
      id: :g,
      component: DexterousLoader.Group,
      config: [%Entry{id: :a, component: ProviderA}, %Entry{id: :b, component: ProviderB}]
    }

    assert {:error, issues} = DexterousLoader.validate([group])
    assert List.keyfind(issues, :cycle, 0)

    # The same cycle broken by isolation: :a reads :key_b in a private realm
    # nobody provides, so there is no edge back to :b.
    broken = %Entry{
      id: :g,
      component: DexterousLoader.Group,
      config: [
        %Entry{id: :a, component: ProviderA, isolate: %{key_b: true}},
        %Entry{id: :b, component: ProviderB}
      ]
    }

    assert :ok = DexterousLoader.validate([broken])
  end
end
