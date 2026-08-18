defmodule Dexterous.HaltedError do
  @moduledoc """
  Raised when a step-boundary guard decides that the in-flight effect sequence
  should stop (paper Algorithm 1 and Section 4.3.2).
  """
  defexception [:message]

  @impl true
  def message(%{message: message}), do: message || "effect halted by guard"
end

defmodule Dexterous.InactiveAccessError do
  @moduledoc """
  Raised when a fiber accesses a coeffect it declares but has not committed —
  the fiber is not loaded (paper Algorithm 6, `INACTIVE_ACCESS`).
  """
  defexception [:key]

  @impl true
  def message(%{key: key}), do: "coeffect #{inspect(key)} is declared but not active"
end

defmodule Dexterous.UndeclaredAccessError do
  @moduledoc """
  Raised when a fiber accesses a coeffect that no fiber in its chain declares
  (paper Algorithm 6, `UNDECLARED_ACCESS`).
  """
  defexception [:key]

  @impl true
  def message(%{key: key}), do: "coeffect #{inspect(key)} is not declared by any fiber in scope"
end
