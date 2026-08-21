defmodule Dexterous.Component do
  @moduledoc """
  Behaviour and DSL for components.

  A component pairs a coeffect specification `inject/0` and a provision
  `provide/0` with an effect function `apply/2` (paper Definition 43, the
  triple `(d, p, e)`). Instantiated with `Dexterous.Context.use/3`, it becomes
  a fiber whose lifecycle is driven reactively against its specification.

      defmodule MyComponent do
        use Dexterous.Component, inject: [:database], provide: [:cache]

        @impl true
        def apply(ctx, config) do
          {:ok, db} = Dexterous.Context.get(ctx, :database)
          # Every Context.set/3 and Context.effect/2 here is tracked and
          # recovered automatically when the fiber unloads; set/3 only
          # accepts the declared provision ([:cache] here).
          :ok
        end
      end

  The macro only declares the specification; enforcement of it happens at
  runtime in `Dexterous.Context.fetch!/2` (paper Algorithm 6).
  """

  @doc """
  The coeffect specification: the keys this component requires. A key may
  pair with component-declared interception metadata (paper Definition 30,
  `d(k)`): `inject: [:database, {:filesystem, %{paths: ~w(/tmp)}}]`. At read
  time the declared metadata is merged with the context-carried metadata
  `ι(k)`, right-biased so the context's layer takes priority.
  """
  @callback inject() :: [Dexterous.Context.key() | {Dexterous.Context.key(), map()}]

  @doc """
  The component-declared interception metadata of the specification,
  `%{key => metadata}`. Derived from `inject/0` by the macro; modules
  implementing the behaviour by hand may export it directly.
  """
  @callback inject_meta() :: %{Dexterous.Context.key() => map()}

  @doc """
  The provision (paper Definition 43, `p`): the keys this component may
  provide — the only keys its effect function is allowed to `Context.set/3`.
  Declaring them lets the runtime check provisions statically: a fiber that
  sets a key outside its provision fails with
  `Dexterous.UndeclaredProvisionError`, and the loader can detect dependency
  cycles and duplicate providers from the declarations alone (paper
  Section 6.5).
  """
  @callback provide() :: [Dexterous.Context.key()]

  @doc """
  The effect function, run whenever the fiber (re)loads. Effects performed
  through the context are tracked; on unload their inverses run in LIFO order.
  """
  @callback apply(Dexterous.Context.t(), config :: term()) :: term()

  @doc """
  Optional. When the loader sees a config-only change for an entry whose
  component exports this callback, the new payload is handed to the running
  fiber instead of rebuilding it (paper Section 5.2.1). Return `:ok` to keep
  the fiber running with the new config, or `:reload` to rebuild in place.

  Effects performed through the context here are tracked like in `apply/2`.
  A raised exception moves the fiber to `:failed` after recovering its
  effects.
  """
  @callback update(Dexterous.Context.t(), old_config :: term(), new_config :: term()) ::
              :ok | :reload

  @optional_callbacks update: 3, provide: 0, inject_meta: 0

  @doc """
  The component's provision, defaulting to `[]` for modules that do not
  export `provide/0` (a module may implement the behaviour by hand).
  """
  def provide_of(component) do
    if Code.ensure_loaded?(component) and function_exported?(component, :provide, 0) do
      component.provide()
    else
      []
    end
  end

  @doc """
  The component's declared coeffect keys, with any `{key, metadata}` pairs
  in `inject/0` reduced to their keys.
  """
  def inject_keys_of(component) do
    component.inject()
    |> Enum.map(fn
      {key, metadata} when is_map(metadata) -> key
      key -> key
    end)
  end

  @doc """
  The component's declared interception metadata, defaulting to `%{}` for
  modules that do not export `inject_meta/0`.
  """
  def inject_meta_of(component) do
    if Code.ensure_loaded?(component) and function_exported?(component, :inject_meta, 0) do
      component.inject_meta()
    else
      %{}
    end
  end

  @doc """
  Reduce a coeffect specification to its keys, dropping any declared
  metadata: `[:a, {:b, %{...}}]` becomes `[:a, :b]`.
  """
  def spec_keys(spec) when is_list(spec) do
    Enum.map(spec, fn
      {key, metadata} when is_map(metadata) -> key
      key -> key
    end)
  end

  @doc """
  The declared interception metadata of a coeffect specification:
  `[:a, {:b, %{...}}]` becomes `%{b => %{...}}`.
  """
  def spec_meta(spec) when is_list(spec) do
    Map.new(spec, fn
      {key, metadata} when is_map(metadata) -> {key, metadata}
      key -> {key, %{}}
    end)
    |> Map.reject(fn {_key, metadata} -> metadata == %{} end)
  end

  defmacro __using__(opts) do
    inject = Keyword.get(opts, :inject, [])
    provide = Keyword.get(opts, :provide, [])

    quote do
      @behaviour Dexterous.Component

      # Evaluated in the caller, so metadata maps (AST at macro time) arrive
      # as runtime values.
      @dexterous_inject unquote(inject)

      @impl true
      def inject, do: Dexterous.Component.spec_keys(@dexterous_inject)

      @impl true
      def inject_meta, do: Dexterous.Component.spec_meta(@dexterous_inject)

      @impl true
      def provide, do: unquote(provide)

      defoverridable inject: 0, inject_meta: 0, provide: 0
    end
  end
end
