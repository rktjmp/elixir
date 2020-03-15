defmodule Diff do
  @moduledoc """
  Utilities for comparing build artifacts.
  """

  @tmp_env_vars ~w(TMPDIR TMP TEMP)s

  @known_chunks ~w(
    abstract_code
    debug_info
    attributes
    compile_info
    exports
    labeled_exports
    imports
    indexed_imports
    locals
    labeled_locals
    atoms
  )a

  @doc """
  Compares the build artififacts of two build directories.
  """
  @spec compare_dirs(Path.t(), Path.t()) ::
          {
            only1_paths :: list(Path.t()),
            only2_paths :: list(Path.t()),
            diff :: list({Path.t(), diff :: String.t()})
          }
  def compare_dirs(dir1, dir2) do
    dir1 = Path.expand(dir1)
    dir2 = Path.expand(dir2)

    assert_dir!(dir1)
    assert_dir!(dir2)

    dir1_paths = relative_paths(dir1)
    dir2_paths = relative_paths(dir2)

    only1_paths = dir1_paths -- dir2_paths
    only2_paths = dir2_paths -- dir1_paths
    common_paths = dir1_paths -- only1_paths
    common_files = Enum.reject(common_paths, &File.dir?/1)

    diff =
      Enum.flat_map(common_files, fn path ->
        file1 = Path.join(dir1, path)
        file2 = Path.join(dir2, path)

        case compare_files(file1, file2) do
          :eq -> []
          {:diff, diff} -> [{path, diff}]
        end
      end)

    {only1_paths, only2_paths, diff}
  end

  @doc """
  Compares the contents of two files.

  If the files are BEAM files, it performs a more human-friendly
  "BEAM-diff".
  """
  @spec compare_files(Path.t(), Path.t()) :: :eq | {:diff, diff :: String.t()}
  def compare_files(file1, file2) do
    content1 = File.read!(file1)
    content2 = File.read!(file2)

    if content1 == content2 do
      :eq
    else
      diff =
        if String.ends_with?(file1, ".beam") do
          beam_diff(content1, content2)
        else
          file_diff(file1, file2)
        end

      {:diff, diff}
    end
  end

  defp beam_diff(content1, content2) do
    tmp_file1 =
      content1
      |> humanize_beam_chunks()
      |> inspect(pretty: true, limit: :infinity)
      |> write_tmp()

    tmp_file2 =
      content2
      |> humanize_beam_chunks()
      |> inspect(pretty: true, limit: :infinity)
      |> write_tmp()

    file_diff(tmp_file1, tmp_file2)
  end

  defp file_diff(file1, file2) do
    {diff, _} = System.cmd("diff", [file1, file2])
    diff
  end

  defp humanize_beam_chunks(beam) do
    with {:ok, :beam_lib, chunks} <- :beam_lib.all_chunks(beam),
         chunk_ids = chunks |> Enum.map(fn {chunk_id, _binary} -> chunk_id end) |> Enum.sort(),
         {:ok, {_module, chunks}} <- :beam_lib.chunks(beam, chunk_ids) do
      Enum.map(chunks, &humanize_beam_chunk/1)
    else
      _ -> beam
    end
  end

  defp humanize_beam_chunk({chunk_id, _} = chunk) when chunk_id in @known_chunks do
    chunk
  end

  defp humanize_beam_chunk({chunk_id, binary}) do
    {chunk_id, :erlang.binary_to_term(binary)}
  end

  defp relative_paths(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, dir))
  end

  defp assert_dir!(dir) do
    unless File.dir?(dir) do
      raise ArgumentError, "#{inspect(dir)} is not a directory"
    end
  end

  defp write_tmp(content) do
    filename = generate_tmp_filename()

    case Enum.find_value(tmp_dirs(), &maybe_write(Path.join(&1, filename), content)) do
      nil -> raise "could not write tmp file"
      path -> path
    end
  end

  defp maybe_write(path, content) do
    case File.write(path, content) do
      :ok -> path
      {:error, _} -> nil
    end
  end

  defp generate_tmp_filename do
    sec = :os.system_time(:second)
    rand = :rand.uniform(999_999_999_999_999)
    scheduler_id = :erlang.system_info(:scheduler_id)

    "tmp-#{sec}-#{rand}-#{scheduler_id}"
  end

  defp tmp_dirs do
    system_tmp_dir = Enum.find_value(@tmp_env_vars, "/tmp", &System.get_env/1)
    cwd_tmp_dir = Path.join(File.cwd!(), "tmp")
    [system_tmp_dir, cwd_tmp_dir]
  end
end

case System.argv() do
  [dir1, dir2] ->
    case Diff.compare_dirs(dir1, dir2) do
      {[], [], []} ->
        IO.puts("#{inspect(dir1)} and #{inspect(dir2)} are equal")

      {only1, only2, diff} ->
        for path <- only1, do: IO.puts("Only in #{dir1}: #{path}")
        for path <- only2, do: IO.puts("Only in #{dir2}: #{path}")
        for {path, diff} <- diff, do: IO.puts("Diff #{path}:\n#{diff}")

        System.halt(1)
    end

  _ ->
    IO.puts("Please, provide two directories as arguments")
    System.halt(1)
end
