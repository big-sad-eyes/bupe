defmodule BUPE.Builder do
  @moduledoc ~S"""
  Elixir EPUB generator

  ## Example

  ```elixir
  config = %BUPE.Config{
    title: "Sample",
    language: "en",
    creator: "John Doe",
    publisher: "Sample",
    date: "2016-06-23T06:00:00Z",
    unique_identifier: "EXAMPLE",
    identifier: "http://example.com/book/jdoe/1",
    pages: ["bacon.xhtml", "egg.xhtml", "ham.xhtml"],
    nav: [
      %{id: "ode-to-bacon", label: "1. Ode to Bacon", content: "bacon.xhtml"},
      %{id: "ode-to-ham", label: "2. Ode to Ham", content: "ham.xhtml"},
      %{id: "ode-to-egg", label: "1. Ode to Egg", content: "egg.xhtml"}
    ]
  })

  BUPE.Builder.save(config, "example.epub")
  ```

  """
  @mimetype "application/epub+zip"
  alias BUPE.Config
  alias BUPE.Builder.Templates

  @container_template File.read!(Path.expand("builder/templates/assets/container.xml", __DIR__))
  @display_options File.read!(Path.expand("builder/templates/assets/com.apple.ibooks.display-options.xml", __DIR__))
  @stylesheet File.read!(Path.expand("builder/templates/css/stylesheet.css", __DIR__))

  @doc """
  Generates an EPUB v3 document
  """
  @spec save(Config.t, Path.t) :: String.t | no_return
  def save(config, output) do
    output = Path.expand(output)

    # TODO: Ask the user if they want to replace the existing file.
    if File.exists?(output) do
      File.rm!(output)
    end

    config = normalize_config(config)
    tmp_dir = generate_tmp_dir(config)

    File.mkdir_p!(Path.join(tmp_dir, "OEBPS"))

    generate_assets(assets(), tmp_dir)

    generate_package(config, tmp_dir)
    generate_ncx(config, tmp_dir)
    # nav file is not supported for EPUB v2
    if config.version == "3.0", do: generate_nav(config, tmp_dir)
    if config.cover, do: generate_title(config, tmp_dir)
    generate_content(config, tmp_dir)
    copy_custom_assets(config, tmp_dir)

    {:ok, epub_file} = generate_epub(tmp_dir, output)

    File.rm_rf!(tmp_dir)

    Path.relative_to_cwd(epub_file)
  end

  defp normalize_config(config) do
    config
    |> modified_date()
    |> check_identifier()
    |> check_files_extension()
    |> check_unique_identifier()
  end

  defp generate_tmp_dir(config) do
    tmp_dir =
      (Keyword.get(config.extras, :tmp_dir) || System.tmp_dir())
      |> Path.join(".bupe/#{uuid4()}")

    if File.exists?(tmp_dir) do
      File.rm_rf!(tmp_dir)
    end

    tmp_dir
  end

  # Package definition builder.
  #
  # According to the EPUB specification, the *Package Document* carries
  # bibliographic and structural metadata about an EPUB Publication, and is thus
  # the primary source of information about how to process and display it.
  #
  # The `package` element is the root container of the Package Document and
  # encapsulates Publication metadata and resource information.
  defp generate_package(config, output) do
    content = Templates.content_template(config)
    File.write!("#{output}/OEBPS/content.opf", content)
  end

  # Navigation Center eXtended definition
  #
  # Keep in mind that the EPUB Navigation Document defined in
  # `BUPE.Builder.Nav` supersedes this definition. According to the EPUB
  # specification:
  #
  # > EPUB 3 Publications may include an NCX (as defined in OPF 2.0.1) for EPUB
  # > 2 Reading System forwards compatibility purposes, but EPUB 3 Reading
  # > Systems must ignore the NCX.
  defp generate_ncx(config, output) do
    content = Templates.ncx_template(config)
    File.write!("#{output}/OEBPS/toc.ncx", content)
  end

  # Navigation Document Definition
  #
  # The TOC nav element defines the primary navigation hierarchy of the document.
  # It conceptually corresponds to a table of contents in a printed work.
  #
  # See [EPUB Navigation Document Definition][nav] for more information.
  #
  # [nav]: http://www.idpf.org/epub/301/spec/epub-contentdocs.html#sec-xhtml-nav-def
  defp generate_nav(config, output) do
    content = Templates.nav_template(config)
    File.write!("#{output}/OEBPS/nav.xhtml", content)
  end

  # Cover page definition for the EPUB document
  defp generate_title(config, output) do
    content = Templates.title_template(config)
    File.write!("#{output}/OEBPS/title.xhtml", content)
  end

  defp copy_custom_assets(config, output) do
    assets_dir = "#{output}/OEBPS/content/assets/"
    File.mkdir_p(assets_dir)
    copy_files(config.styles ++ config.scripts ++ config.images, assets_dir)
  end

  defp generate_content(config, output) do
      output = Path.join(output, "OEBPS/content")
      File.mkdir! output
      copy_files(config.pages, output)
  end

  defp generate_epub(input, output) do
    :zip.create(String.to_charlist(output),
                [{'mimetype', @mimetype} | files_to_add(input)],
                compress: ['.css', '.js', '.html', '.xhtml', '.ncx',
                            '.opf', '.jpg', '.png', '.xml'])
  end

  ## Helpers
  defp modified_date(%{modified: nil} = config) do
    dt = DateTime.utc_now() |> Map.put(:microsecond, {0, 0}) |> DateTime.to_iso8601()
    Map.put(config, :modified, dt)
  end

  # TODO: Check if format is compatible with ISO8601
  defp modified_date(config), do: config

  defp check_identifier(%{identifier: nil} = config) do
    identifier = "urn:uuid:#{uuid4()}"
    Map.put(config, :identifier, identifier)
  end

  defp check_identifier(config), do: config

  defp check_files_extension(config) do
    check_extension_name(config)

    config
  end

  defp check_extension_name(%{version: "3.0"} = config) do
    if invalid_files?(config.pages, [".xhtml"]) do
      raise Config.InvalidExtensionName, "XHTML Content Document file names should have the extension '.xhtml'."
    end
  end

  defp check_extension_name(%{version: "2.0"} = config) do
    if invalid_files?(config.pages, [".html", ".htm", ".xhtml"]) do
      raise Config.InvalidExtensionName, "invalid file extension for HTML file, expected '.html', '.htm' or '.xhtml'"
    end
  end

  defp check_extension_name(_config), do: raise Config.InvalidVersion

  defp check_unique_identifier(%{unique_identifier: nil} = config), do: Map.put(config, :unique_identifier, "BUPE")
  defp check_unique_identifier(config), do: config

  defp invalid_files?(files, extensions) do
    Enum.filter(files, &((Path.extname(&1) |> String.downcase()) in extensions)) != files
  end

  defp files_to_add(path) do
    Enum.reduce Path.wildcard(Path.join(path, "**/*")), [], fn(file, acc) ->
      case File.read(file) do
        {:ok, bin} ->
          [{file |> Path.relative_to(path) |> String.to_charlist(), bin} | acc]
        {:error, _} ->
          acc
      end
    end
  end

  defp assets do
    [
      [content: @stylesheet, dir: "OEBPS/css", filename: "stylesheet.css"],
      [content: @container_template, dir: "META-INF", filename: "container.xml"],
      [content: @display_options, dir: "META-INF", filename: "com.apple.ibooks.display-options.xml"]
    ]
  end

  defp generate_assets(assets, output) do
    Enum.each assets, fn(asset) ->
      output = "#{output}/#{asset[:dir]}"
      File.mkdir(output)

      output
      |> Path.join(asset[:filename])
      |> File.write!(asset[:content])
    end
  end

  defp copy_files(files, output) do
    Enum.map files, fn(file) ->
      base = Path.basename(file)
      File.copy file, "#{output}/#{base}"
    end
  end

  # Helper to generate an UUID, in particular version 4 as specified in
  # [RFC 4122](https://tools.ietf.org/html/rfc4122.html)
  defp uuid4 do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    bin = <<u0::48, 4::4, u1::12, 2::2, u2::62>>
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = bin

    Enum.map_join([<<u0::32>>, <<u1::16>>, <<u2::16>>, <<u3::16>>, <<u4::48>>], <<45>>,
                  &(Base.encode16(&1, case: :lower)))
  end
end
