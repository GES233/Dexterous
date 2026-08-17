defmodule Dexterous.Component do
  @moduledoc """
  Behaviour and DSL for components.

  A component pairs a coeffect specification `inject/0` with an effect
  function `apply/2`. Instantiated with `Dexterous.Context.use/3`, it becomes
  a fiber whose lifecycle is driven reactively against its specification.

      defmodule MyComponent do
        use Dexterous.Component, inject: [:database]

        @impl true
        def apply(ctx, config) do
          {:ok, db} = Dexterous.Context.get(ctx, :database)
          # Every Context.set/3 and Context.effect/2 here is tracked and
          # recovered automatically when the fiber unloads.
          :ok
        end
      end

  The macro only declares the specification; enforcement of it happens at
  runtime in `Dexterous.Context.fetch!/2` (paper Algorithm 6).
  """

  @doc "The coeffect specification: the keys this component requires."
  @callback inject() :: [Dexterous.Context.key()]

  @doc """
  The effect function, run whenever the fiber (re)loads. Effects performed
  through the context are tracked; on unload their inverses run in LIFO order.
  """
  @callback apply(Dexterous.Context.t(), config :: term()) :: term()

  defmacro __using__(opts) do
    inject = Keyword.get(opts, :inject, [])

    unless is_list(inject) do
      raise ArgumentError, ":inject must be a list of coeffect keys"
    end

    quote do
      @behaviour Dexterous.Component

      @impl true
      def inject, do: unquote(inject)

      defoverridable inject: 0
    end
  end
end
