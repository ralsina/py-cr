# Example py-cr module: tartrazine as `import tartrazine`.
#
# Everything here is ordinary py-cr DSL plus ordinary tartrazine calls;
# no framework code was touched to make this work.

require "py-cr"
require "tartrazine"

# A wrapped tartrazine lexer, annotation style.
@[Pycr::PyClass("tartrazine.Lexer")]
class Lexer < Pycr::PyObject
  @[Pycr::PyNew]
  def initialize(name : String)
    @name = name
    @lexer = Tartrazine.lexer(name: name)
  end

  @[Pycr::PyAttr]
  def name : String
    @name
  end

  @[Pycr::PyMethod]
  def tokenize(text : String) : Array(Tuple(String, String))
    tokens = [] of Tuple(String, String)
    @lexer.tokenizer(text).each do |token|
      tokens << {token[:type], token[:value]}
    end
    tokens
  end

  @[Pycr::PyRepr]
  def describe : String
    "Lexer(#{@name})"
  end
end

Pycr.pyinit "tartrazine" do
  Pycr.pyfunction def version : String
    "tartrazine #{Tartrazine::VERSION} / Crystal #{Crystal::VERSION}"
  end

  Pycr.pyfunction def highlight(code : String, language : String, theme : String = "default-dark",
                                standalone : Bool = false, line_numbers : Bool = false) : String
    Tartrazine.to_html(code, language: language, theme: theme,
      standalone: standalone, line_numbers: line_numbers)
  end

  # Token stream without going through a formatter.
  Pycr.pyfunction def tokenize(code : String, language : String) : Array(Tuple(String, String))
    tokens = [] of Tuple(String, String)
    Tartrazine.lexer(name: language).tokenizer(code).each do |token|
      tokens << {token[:type], token[:value]}
    end
    tokens
  end

  Pycr.pyfunction def themes : Array(String)
    Tartrazine.themes.to_a.sort
  end
end
