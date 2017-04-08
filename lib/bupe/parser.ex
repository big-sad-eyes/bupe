defmodule BUPE.Parser do
  @moduledoc ~S"""
  An [EPUB 3][EPUB] conforming parser. This implementation should support also
  EPUB 2.

  ## Example

  ```iex
  BUPE.Parser.parse("sample.epub")
  #=> %BUPE.Config{
        title: "Sample",
        creator: "John Doe",
        unique_identifier: "EXAMPLE",
        pages: ["bacon.xhtml", "ham.xhtml", "egg.xhtml"],
        nav: [
          %{id: "ode-to-bacon", label: "1. Ode to Bacon", content: "bacon.xhtml"},
          %{id: "ode-to-ham", label: "2. Ode to Ham", content: "ham.xhtml"},
          %{id: "ode-to-egg", label: "3. Ode to Egg", content: "egg.xhtml"}
        ]
      }
  ```

  [EPUB]: http://www.idpf.org/epub3/latest/overview

  """

  @doc """
  EPUB v3 parser
  """
  @spec parse(Path.t) :: BUPE.Config.t | no_return
  def parse(epub_file) when is_binary(epub_file) do
    epub_file = Path.expand(epub_file)

    check_file(epub_file)
    check_extension(epub_file)
    check_mimetype(epub_file)
    epub_file |> find_rootfile() |> extract_info(epub_file)
  end

  defp check_file(epub_file) do
    unless File.exists?(epub_file) do
      raise ArgumentError, "file #{epub_file} does not exists"
    end
  end

  defp check_extension(epub_file) do
    unless epub_file |> Path.extname() |> String.downcase() == ".epub" do
      raise ArgumentError, "file #{epub_file} does not have an '.epub' extension"
    end
  end

  defp check_mimetype(epub_file) do
    unless epub_file |> extract_content(["mimetype"]) |> mimetype_valid?() do
      raise "invalid mimetype, must be 'application/epub+zip'"
    end
  end

  defp mimetype_valid?([{'mimetype', "application/epub+zip"}]), do: true
  defp mimetype_valid?(_), do: false

  defp find_rootfile(epub_file) do
    container = 'META-INF/container.xml'
    [{^container, content}] = extract_content(epub_file, [container])
    captures = Regex.named_captures(~r/<rootfile\s.*full-path="(?<full_path>[^"]+)"\s/, content)

    unless captures do
      raise "could not find rootfile in META-INF/container.xml"
    end

    captures["full_path"]
  end

  defp extract_info(root_file, epub_file) do
    root_file = String.to_charlist(root_file)
    [{^root_file, content}] = extract_content(epub_file, [root_file])

    {xml, _rest} = :erlang.bitstring_to_list(content) |>  :xmerl_scan.string

    %BUPE.Config{
      title: find_metadata(xml, "title"),
      language: find_language(xml),
      version: find_version(xml),
      #identifier: find_isbn(xml),
      identifier: find_identifiers(xml),
      creator: find_metadata(xml, "creator"),
      contributor: find_metadata(xml, "contributor"),
      modified: find_modified(xml),
      date: find_metadata(xml, "date"),
      unique_identifier: find_unique_identifier(xml),
      source: find_metadata(xml, "source"),
      type: find_metadata(xml, "type"),
      description: find_metadata(xml, "description"),
      format: find_metadata(xml, "format"),
      coverage: find_metadata(xml, "coverage"),
      publisher: find_metadata(xml, "publisher"),
      relation: find_metadata(xml, "relation"),
      rights: find_metadata(xml, "rights"),
      subject: find_metadata(xml, "subject"),
      pages: nil,
      nav: nil
    }
  end

  defp extract_content(epub_file, files) when is_list(files) do
    archive = String.to_charlist(epub_file)
    file_list = Enum.into files, [], &(if is_list(&1), do: &1, else: String.to_charlist(&1))

    case :zip.extract(archive, [{:file_list, file_list}, :memory]) do
      {:ok, content} ->
        content
      {:error, reason} ->
        raise reason
    end
  end

  defp find_metadata(xml, meta) do
    "/package/metadata/dc:#{meta} | /package/metadata/#{meta}"
    |> xpath_string(xml)
    |> parse_record()
  end


  defp xpath_string(xpath, xml) do
    xpath
    |> :erlang.bitstring_to_list
    |> :xmerl_xpath.string(xml)
  end

  defp find_modified(xml) do
    "/package/metadata/meta[contains(@property, 'dcterms:modified')]"
    |> xpath_string(xml)
    |> parse_record()
  end

  defp find_version(xml) do
    "/package/@version"
    |> xpath_string(xml)
    |> parse_xml_attribute()
  end

  defp find_language(xml) do
    find_metadata(xml, "language") || xpath_string("/package/@xml:lang", xml) |> parse_xml_attribute()
  end

  defp find_unique_identifier(xml) do
    "/package/@unique-identifier"
    |> xpath_string(xml)
    |> parse_xml_attribute()
  end

  # example of more advanced xpath query -- not needed as just querying
  # map returned by identifiers is better solution but this should be a good
  # example of selecting by attribute values with xpath query
  # 
  #defp find_isbn(xml) do
  #  "/package/metadata/dc:identifier[@*[. = 'ISBN'] | @*[. = 'isbn']]" 
  #  |> xpath_string(xml)
  #  |> parse_record()
  #end


  defp find_identifiers(xml) do
    "/package/metadata/dc:identifier"
    |> xpath_string(xml)
    |> parse_identifiers()
  end





  defp parse_record([]), do: nil
  defp parse_record([element]), do: combine_values(pr(element))
  defp parse_record([head_element | tail_elements]), do: [ combine_values(pr([head_element])) | pr(tail_elements) ]


  defp combine_values([]), do: nil
  defp combine_values(values) when not is_list(values), do: values
  defp combine_values(values) when     is_list(values), do: List.to_string( Enum.map(values,fn(v) -> to_string(v) end) )

  
  defp pr(nil), do: []
  defp pr([]), do: []
  defp pr([{:xmlElement, _name, _, _, _, _, _, _attributes, elements, _, _, _} | tail]), do: [ combine_values(pr(elements)) | pr(tail) ]
  defp pr({:xmlElement, _name, _, _, _, _, _, _attributes, elements, _, _, _}), do: pr(elements)
  defp pr([{:xmlComment, _, _, _, _value}]), do: []
  defp pr({:xmlComment, _, _, _, _value}), do: []
  defp pr([{:xmlText, _, _, _, value, _} | tail]), do: [to_string(value) | [combine_values(pr(tail))] ]
  defp pr({:xmlText, _, _, _, value, _}), do: to_string(value)


  defp parse_xml_attribute([{:xmlAttribute, _name, _expanded_name, _nsinfo, _namespace, _parents, _pos, _language, value, _normalized}]), do: to_string(value)
  defp parse_xml_attribute([]), do: nil


  defp parse_identifiers([]), do: nil
  defp parse_identifiers([head_element | tail_elements]) do
    Enum.map([head_element | tail_elements ], fn(e) -> parse_identifiers(e) end )
    |> Enum.into(%{})
  end
  defp parse_identifiers({:xmlElement, _name, _, _, _, _, _, attributes, elements, _, _, _}) do
    ident_id=parse_identifier_attributes(attributes)
    if ident_id != nil do
      id = elem(ident_id,1)
      val = parse_record(elements)
      {id, val}
    else
      nil
    end
  end


  defp parse_identifier_attributes([head_element | tail_elements]) do
    Enum.map([head_element | tail_elements ], fn(e) -> parse_identifier_attributes(e) end )
    |> Enum.reduce(nil, fn(at,acc) -> combine_identifier_attributes(at,acc) end )                                    
  end
  defp parse_identifier_attributes( {:xmlAttribute, name, _expanded_name, _nsinfo, _namespace, _parents, _pos, _language, value, _normalized} ) do
    nstr = to_string(name)
    cond do
      String.match?(nstr, ~r/:scheme$/) || String.match?(nstr, ~r/^scheme$/) ->
        {:scheme, value}
      String.match?(nstr, ~r/^id$/) ->
        {:id, value}
      true ->
        nil
    end
  end
  defp parse_identifier_attributes(nil), do: nil

  defp combine_identifier_attributes({:id,value},_), do: {:id, value}
  defp combine_identifier_attributes(_,{:id,value}), do: {:id, value}
  defp combine_identifier_attributes(t,nil), do: t


end



