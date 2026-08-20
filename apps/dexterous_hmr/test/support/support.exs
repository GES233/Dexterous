defmodule DexterousHMR.TestSupport do
  @moduledoc false
  # Test fixtures: versions of small component modules, compiled from source
  # strings into real BEAM binaries so md5 diffing and `:code.load_binary`
  # rollback behave exactly as in dev.

  # The fixtures deliberately redefine already-loaded modules (that is the
  # point of HMR), so silence the "redefining module" warning.
  Code.put_compiler_option(:ignore_module_conflict, true)

  @tmp_base Path.join(System.tmp_dir!(), "dexterous_hmr_fixtures")

  def tmp_dir, do: @tmp_base

  # NB: deliberately NOT under a Dexterous* namespace — the HMR protection
  # refuses framework-prefixed modules, which would classify the fixtures as
  # protected and skip them.
  def module_name(name) do
    Module.concat([HmrFixture, name |> Atom.to_string() |> Macro.camelize()])
  end

  def source(name, :v1) do
    mod = module_name(name)

    """
    defmodule #{inspect(mod)} do
      use Dexterous.Component

      @impl true
      def apply(ctx, config) do
        send(config[:test], {:applied, #{inspect(mod)}, 1})

        Dexterous.Context.effect(ctx, fn _ ->
          fn -> send(config[:test], {:disposed, #{inspect(mod)}, 1}) end
        end)
      end
    end
    """
  end

  def source(name, :v2) do
    mod = module_name(name)

    """
    defmodule #{inspect(mod)} do
      use Dexterous.Component

      @impl true
      def apply(ctx, config) do
        send(config[:test], {:applied, #{inspect(mod)}, config[:version]})

        Dexterous.Context.effect(ctx, fn _ ->
          fn -> send(config[:test], {:disposed, #{inspect(mod)}, config[:version]}) end
        end)
      end
    end
    """
  end

  def source(name, :bad) do
    mod = module_name(name)

    """
    defmodule #{inspect(mod)} do
      use Dexterous.Component

      @impl true
      def apply(_ctx, _config) do
        raise "fixture boom"
      end
    end
    """
  end

  def source(name, :slow) do
    mod = module_name(name)

    """
    defmodule #{inspect(mod)} do
      use Dexterous.Component

      @impl true
      def apply(ctx, config) do
        Process.sleep(config[:sleep])
        send(config[:test], {:applied, #{inspect(mod)}, :slow})

        Dexterous.Context.effect(ctx, fn _ ->
          fn -> send(config[:test], {:disposed, #{inspect(mod)}, :slow}) end
        end)
      end
    end
    """
  end

  @doc """
  Write `name`/`version`'s source under the fixture tmp dir, compile it to a
  BEAM binary and load it. Returns `{module, binary, source_path}`.
  """
  def compile_and_load(name, version) do
    mod = module_name(name)
    dir = Path.join(@tmp_base, "#{name}_#{version}")
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    path = Path.join(dir, "widget.ex")
    File.write!(path, source(name, version))

    case Kernel.ParallelCompiler.compile_to_path([path], ebin, return_diagnostics: true) do
      {:ok, [^mod], _warnings} ->
        beam = Path.join(ebin, "Elixir." <> module_filename(mod) <> ".beam")
        binary = File.read!(beam)
        :code.load_binary(mod, String.to_charlist(beam), binary)
        {mod, binary, path}

      other ->
        raise "fixture compile failed: #{inspect(other)}"
    end
  end

  @doc "A backup map (pre-compile object code) for `mod` with `binary`."
  def backup(mod, binary, path) do
    %{mod => %{binary: binary, file: path <> ".beam"}}
  end

  defp module_filename(mod) do
    Atom.to_string(mod) |> String.trim_leading("Elixir.")
  end
end
