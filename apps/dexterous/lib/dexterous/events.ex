defmodule Dexterous.Events do
  @moduledoc """
  The typed-event dispatch engine: pure dispatch over a listener list.

  Listeners are functions in one of two shapes:

    * arity 1 — `fn payload -> result end`
    * arity 2 — `fn payload, next -> result end`, where `next` is a
      continuation `fn new_payload -> result end`

  How `result` and `next` are interpreted depends on the dispatch mode:

    * `emit/2` — run every listener for its side effects, in registration
      order; results are discarded and the call returns `:ok`. In arity-2
      listeners `next` is a no-op identity.
    * `serial/2` — run every listener in registration order, collecting the
      results into a list. In arity-2 listeners `next` is a no-op identity.
    * `waterfall/2` — a middleware chain over the payload. An arity-1
      listener's return value becomes the payload for the rest of the chain;
      an arity-2 listener must call `next.(new_payload)` to delegate (and may
      transform the payload doing so), or decline to call it to short-circuit
      the chain. Returns the final payload.
    * `bail/2` — run listeners in registration order until one returns a
      non-`nil` result, which becomes the return value; `nil` means "no
      opinion". Returns `nil` when no listener has an opinion.

  Dispatch is synchronous in the caller's process: a slow listener blocks the
  emitter, and listener exceptions propagate to it.
  """

  @type event :: term()
  @type payload :: term()
  @type listener :: (payload() -> term()) | (payload(), (payload() -> term()) -> term())

  @doc "Run every listener for side effects, in order. Always returns `:ok`."
  @spec emit([listener()], payload()) :: :ok
  def emit(listeners, payload) do
    Enum.each(listeners, &call(&1, payload))
    :ok
  end

  @doc "Run every listener in order, collecting results into a list."
  @spec serial([listener()], payload()) :: [term()]
  def serial(listeners, payload) do
    Enum.map(listeners, &call(&1, payload))
  end

  @doc """
  Run the middleware chain over `payload`. Arity-2 listeners delegate with
  `next.(new_payload)` or short-circuit by not calling it; arity-1 listeners
  implicitly delegate with their return value. Returns the final payload.
  """
  @spec waterfall([listener()], payload()) :: payload()
  def waterfall(listeners, payload) do
    run_chain(listeners, payload)
  end

  @doc """
  Run listeners in order until one returns a non-`nil` result. Returns that
  result, or `nil` when every listener declined.
  """
  @spec bail([listener()], payload()) :: term() | nil
  def bail(listeners, payload) do
    Enum.reduce_while(listeners, nil, fn listener, _acc ->
      case call(listener, payload) do
        nil -> {:cont, nil}
        result -> {:halt, result}
      end
    end)
  end

  ## Internal

  defp run_chain([], payload), do: payload

  defp run_chain([listener | rest], payload) do
    case arity(listener) do
      1 -> run_chain(rest, listener.(payload))
      2 -> listener.(payload, fn new_payload -> run_chain(rest, new_payload) end)
    end
  end

  defp call(listener, payload) do
    case arity(listener) do
      1 -> listener.(payload)
      2 -> listener.(payload, fn payload -> payload end)
    end
  end

  defp arity(fun) do
    {:arity, arity} = Function.info(fun, :arity)
    arity
  end
end
