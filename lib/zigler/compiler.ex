defmodule Zigler.Compiler do

  @moduledoc false

  @enforce_keys [:staging_dir, :code_file, :module_spec]

  # contains critical information for the compilation.
  defstruct @enforce_keys

  @type t :: %__MODULE__{
    staging_dir: Path.t,
    code_file:   Path.t,
    module_spec: Zigler.Module.t
  }

  require Logger

  alias Zigler.Compiler.ErrorParser
  alias Zigler.Import
  alias Zigler.Zig

  @zig_dir_path Path.expand("../../../zig", __ENV__.file)
  @erl_nif_zig_h Path.join(@zig_dir_path, "include/erl_nif_zig.h")
  @erl_nif_zig Path.join(@zig_dir_path, "beam/erl_nif.zig")

  @doc false
  def basename(version) do
    os = case :os.type do
      {:unix, :linux} ->
        "linux"
      {:unix, :freebsd} ->
        "freebsd"
      {:unix, :darwin} ->
        Logger.warn("macos support is experimental")
        "macos"
      {:win32, _} ->
        Logger.error("windows is definitely not supported.")
        "windows"
    end
    "zig-#{os}-x86_64-#{version}"
  end

  @release_mode %{
    fast:  ["--release-fast"],
    safe:  ["--release-safe"],
    small: ["--release-small"],
    debug: []
  }

  defmacro __before_compile__(context) do

    ###########################################################################
    # VERIFICATION

    module = Module.get_attribute(context.module, :zigler)

    zig_tree = Path.join(@zig_dir_path, basename(module.zig_version))

    # check to see if the zig version has been downloaded.
    unless File.dir?(zig_tree) do
      raise CompileError,
        file: context.file,
        line: context.line,
        description: "zig hasn't been downloaded.  Run mix zigler.get_zig #{module.zig_version}"
    end

    ###########################################################################
    # COMPILATION STEPS

    compiler = precompile(module)
    unless module.dry_run do
      compile(compiler, zig_tree)
    end
    cleanup(compiler)

    ###########################################################################
    # MACRO SETPS

    nif_functions = Enum.map(module.nifs, &function_skeleton/1)

    mod_path = module.app
    |> Zigler.nif_dir
    |> Path.join(Zigler.nif_name(module, false))

    if module.dry_run do
      quote do
        unquote_splicing(nif_functions)
        def __load_nifs__, do: :ok
      end
    else
      quote do
        import Logger
        unquote_splicing(nif_functions)
        def __load_nifs__ do
          unquote(mod_path)
          |> String.to_charlist()
          |> :erlang.load_nif(0)
          |> case do
            :ok -> :ok
            {:error, any} ->
              Logger.error("problem loading module #{inspect any}")
          end
        end
      end
    end
  end

  #############################################################################
  ## FUNCTION SKELETONS

  alias Zigler.Code.LongRunning
  alias Zigler.Typespec
  alias Zigler.Parser.Nif

  def function_skeleton(nif = %Nif{opts: opts}) do
    typespec = Typespec.from_nif(nif)
    if opts[:long] do
      {:__block__, _, block_contents} = LongRunning.function_skeleton(nif)
      quote do
        unquote(typespec)
        unquote_splicing(block_contents)
      end
    else
      quote do
        unquote(typespec)
        unquote(basic_fn(nif))
      end
    end
  end

  defp basic_fn(%{name: name, arity: arity}) do
    text = "nif for function #{name}/#{arity} not bound"

    params = if arity == 0 do
      Elixir
    else
      for _ <- 1..arity, do: {:_, [], Elixir}
    end

    {:def, [context: Elixir, import: Kernel],
      [
        {name, [context: Elixir], params},
        [do: {:raise, [context: Elixir, import: Kernel], [text]}]
      ]}
  end

  #############################################################################
  ## STEPS

  @staging_root Application.get_env(:zigler, :staging_root, "/tmp/zigler_compiler")

  @spec precompile(Zigler.Module.t) :: t | no_return
  def precompile(module) do
    # build the staging directory.
    staging_dir = Path.join([@staging_root, Atom.to_string(Mix.env()), "#{module.module}"])
    File.mkdir_p(staging_dir)

    # define the code file and build it.
    code_file = Path.join(staging_dir, "#{module.module}.zig")
    File.write!(code_file, Zigler.Code.generate_main(module))

    # copy in beam.zig
    File.cp!("zig/beam/beam.zig", Path.join(staging_dir, "beam.zig"))
    # copy in erl_nif.zig
    File.cp!("zig/beam/erl_nif.zig", Path.join(staging_dir, "erl_nif.zig"))
    # copy in erl_nif_zig.h
    File.mkdir_p!(Path.join(staging_dir, "include"))
    File.cp!("zig/include/erl_nif_zig.h", Path.join(staging_dir, "include/erl_nif_zig.h"))

    # assemble the module struct
    %__MODULE__{
      staging_dir: staging_dir,
      code_file:   code_file,
      module_spec: module
    }
  end

  @spec compile(t, Path.t) :: :ok | no_return
  defp compile(compiler, zig_tree) do
    # first move everything into the staging directory.
    Zig.compile(compiler, zig_tree)
    :ok
  end

  @spec cleanup(t) :: :ok | no_return
  defp cleanup(compiler) do
    # in dev and test we keep our code around for debugging purposes.
    # TODO: make this configurable.
    if Mix.env in [:dev, :prod] do
      File.rm_rf!(compiler.staging_dir)
    end
    :ok
  end
end
