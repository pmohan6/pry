class Pry
  class << self
    # Convert the given object into an instance of `Pry::Code`, if it isn't
    # already one.
    #
    # @param [Code, Method, UnboundMethod, Proc, Pry::Method, String, Array,
    #   IO] obj
    def Code(obj)
      case obj
      when Code
        obj
      when ::Method, UnboundMethod, Proc, Pry::Method
        Code.from_method(obj)
      else
        Code.new(obj)
      end
    end
  end

  # `Pry::Code` is a class that encapsulates lines of source code and their
  # line numbers and formats them for terminal output. It can read from a file
  # or method definition or be instantiated with a `String` or an `Array`.
  #
  # In general, the formatting methods in `Code` return a new `Code` object
  # which will format the text as specified when `#to_s` is called. This allows
  # arbitrary chaining of formatting methods without mutating the original
  # object.
  class Code
    class << self
      include MethodSource::CodeHelpers

      # Instantiate a `Code` object containing code loaded from a file or
      # Pry's line buffer.
      #
      # @param [String] filename The name of a file, or "(pry)".
      # @param [Symbol] code_type The type of code the file contains.
      # @return [Code]
      def from_file(filename, code_type = type_from_filename(filename))
        if filename == Pry.eval_path
          new(Pry.line_buffer.drop(1), 1, code_type)
        else
          File.open(get_abs_path(filename), 'r') { |f| new(f, 1, code_type) }
        end
      end

      # Instantiate a `Code` object containing code extracted from a
      # `::Method`, `UnboundMethod`, `Proc`, or `Pry::Method` object.
      #
      # @param [::Method, UnboundMethod, Proc, Pry::Method] meth The method
      #   object.
      # @param [Integer, nil] start_line The line number to start on, or nil to
      #   use the method's original line numbers.
      # @return [Code]
      def from_method(meth, start_line=nil)
        meth = Pry::Method(meth)
        start_line ||= meth.source_line || 1
        new(meth.source, start_line, meth.source_type)
      end

      # Attempt to extract the source code for module (or class) `mod`.
      #
      # @param [Module, Class] mod The module (or class) of interest.
      # @param [Integer, nil] start_line The line number to start on, or nil to use the
      #   method's original line numbers.
      # @param [Integer] candidate_rank The module candidate (by rank)
      #   to use (see `Pry::WrappedModule::Candidate` for more information).
      # @return [Code]
      def from_module(mod, start_line=nil, candidate_rank=0)
        candidate = Pry::WrappedModule(mod).candidate(candidate_rank)

        start_line ||= candidate.line
        new(candidate.source, start_line, :ruby)
      end

      protected

      # Guess the CodeRay type of a file from its extension, or nil if
      # unknown.
      #
      # @param [String] filename
      # @param [Symbol] default (:ruby) the file type to assume if none could be detected
      # @return [Symbol, nil]
      def type_from_filename(filename, default=:ruby)
        map = {
          %w(.c .h) => :c,
          %w(.cpp .hpp .cc .h cxx) => :cpp,
          %w(.rb .ru .irbrc .gemspec .pryrc) => :ruby,
          %w(.py) => :python,
          %w(.diff) => :diff,
          %w(.css) => :css,
          %w(.html) => :html,
          %w(.yaml .yml) => :yaml,
          %w(.xml) => :xml,
          %w(.php) => :php,
          %w(.js) => :javascript,
          %w(.java) => :java,
          %w(.rhtml) => :rhtml,
          %w(.json) => :json
        }

        _, type = map.find do |k, _|
          k.any? { |ext| ext == File.extname(filename) }
        end

        type || default
      end

      # @param [String] filename
      # @raise [MethodSource::SourceNotFoundError] if the +filename+ is not
      #   readable for some reason.
      # @return [String] absolute path for the given +filename+.
      def get_abs_path(filename)
        abs_path = [File.expand_path(filename, Dir.pwd),
                    File.expand_path(filename, Pry::INITIAL_PWD)
                   ].detect { |abs_path| File.readable?(abs_path) }
        abs_path or raise MethodSource::SourceNotFoundError,
                          "Cannot open #{filename.inspect} for reading."
      end
    end

    # @return [Symbol] The type of code stored in this wrapper.
    attr_accessor :code_type

    # Instantiate a `Code` object containing code from the given `Array`,
    # `String`, or `IO`. The first line will be line 1 unless specified
    # otherwise. If you need non-contiguous line numbers, you can create an
    # empty `Code` object and then use `#push` to insert the lines.
    #
    # @param [Array<String>, String, IO] lines
    # @param [Integer?] start_line
    # @param [Symbol?] code_type
    def initialize(lines=[], start_line=1, code_type=:ruby)
      if lines.is_a? String
        lines = lines.lines
      end

      @lines = lines.each_with_index.map { |l, i| [l.chomp, i + start_line.to_i] }
      @code_type = code_type
    end

    # Append the given line. `line_num` is one more than the last existing
    # line, unless specified otherwise.
    #
    # @param [String] line
    # @param [Integer?] line_num
    # @return [String] The inserted line.
    def push(line, line_num=nil)
      line_num = @lines.last.last + 1 unless line_num
      @lines.push([line.chomp, line_num])
      line
    end
    alias << push

    # Filter the lines using the given block.
    #
    # @yield [line]
    # @return [Code]
    def select(&blk)
      alter do
        @lines = @lines.select(&blk)
      end
    end

    # Remove all lines that aren't in the given range, expressed either as a
    # `Range` object or a first and last line number (inclusive). Negative
    # indices count from the end of the array of lines.
    #
    # @param [Range, Integer] start_line
    # @param [Integer?] end_line
    # @return [Code]
    def between(start_line, end_line=nil)
      return self unless start_line

      start_line, end_line = reform_start_and_end_lines(start_line, end_line)
      start_idx,  end_idx  = start_and_end_indices(start_line, end_line)

      alter do
        @lines = @lines[start_idx..end_idx] || []
      end
    end

    # Take `num_lines` from `start_line`, forward or backwards
    #
    # @param [Integer] start_line
    # @param [Integer] num_lines
    # @return [Code]
    def take_lines(start_line, num_lines)
      if start_line >= 0
        start_idx = @lines.index { |l| l.last >= start_line } || @lines.length
      else
        start_idx = @lines.length + start_line
      end

      alter do
        @lines = @lines.slice(start_idx, num_lines)
      end
    end

    # Remove all lines except for the `lines` up to and excluding `line_num`.
    #
    # @param [Integer] line_num
    # @param [Integer] lines
    # @return [Code]
    def before(line_num, lines=1)
      return self unless line_num

      select do |l, ln|
        ln >= line_num - lines && ln < line_num
      end
    end

    # Remove all lines except for the `lines` on either side of and including
    # `line_num`.
    #
    # @param [Integer] line_num
    # @param [Integer] lines
    # @return [Code]
    def around(line_num, lines=1)
      return self unless line_num

      select do |l, ln|
        ln >= line_num - lines && ln <= line_num + lines
      end
    end

    # Remove all lines except for the `lines` after and excluding `line_num`.
    #
    # @param [Integer] line_num
    # @param [Integer] lines
    # @return [Code]
    def after(line_num, lines=1)
      return self unless line_num

      select do |l, ln|
        ln > line_num && ln <= line_num + lines
      end
    end

    # Remove all lines that don't match the given `pattern`.
    #
    # @param [Regexp] pattern
    # @return [Code]
    def grep(pattern)
      return self unless pattern
      pattern = Regexp.new(pattern)

      select do |l, ln|
        l =~ pattern
      end
    end

    # Format output with line numbers next to it, unless `y_n` is falsy.
    #
    # @param [Boolean?] y_n
    # @return [Code]
    def with_line_numbers(y_n=true)
      alter do
        @with_line_numbers = y_n
      end
    end

    # Format output with a marker next to the given `line_num`, unless `line_num`
    # is falsy.
    #
    # @param [Integer?] line_num
    # @return [Code]
    def with_marker(line_num=1)
      alter do
        @with_marker     = !!line_num
        @marker_line_num = line_num
      end
    end

    # Format output with the specified number of spaces in front of every line,
    # unless `spaces` is falsy.
    #
    # @param [Integer?] spaces
    # @return [Code]
    def with_indentation(spaces=0)
      alter do
        @with_indentation = !!spaces
        @indentation_num  = spaces
      end
    end

    # @return [String]
    def inspect
      Object.instance_method(:to_s).bind(self).call
    end

    # @return [String] a formatted representation (based on the configuration of
    #   the object).
    def to_s
      lines = @lines.map(&:dup).each do |line|
        add_color(line)        if Pry.color
        add_line_numbers(line) if @with_line_numbers
        add_marker(line)       if @with_marker
        add_indentation(line)  if @with_indentation
      end
      lines.map { |line| "#{ line[0] }\n" }.join
    end

    # Get the comment that describes the expression on the given line number.
    #
    # @param [Integer]  line_number (1-based)
    # @return [String]  the code.
    def comment_describing(line_number)
      self.class.comment_describing(raw, line_number)
    end

    # Get the multiline expression that starts on the given line number.
    #
    # @param [Integer]  line_number (1-based)
    # @return [String]  the code.
    def expression_at(line_number, consume=0)
      self.class.expression_at(raw, line_number, :consume => consume)
    end

    # Get the (approximate) Module.nesting at the give line number.
    #
    # @param [Integer]  line_number  line number starting from 1
    # @param [Module] top_module   the module in which this code exists
    # @return [Array<Module>]  a list of open modules.
    def nesting_at(line_number, top_module=Object)
      Pry::Indent.nesting_at(raw, line_number)
    end

    # Return an unformatted String of the code.
    #
    # @return [String]
    def raw
      @lines.map(&:first).join("\n") + "\n"
    end

    # Return the number of lines stored.
    #
    # @return [Integer]
    def length
      @lines ? @lines.length : 0
    end

    # Two `Code` objects are equal if they contain the same lines with the same
    # numbers. Otherwise, call `to_s` and `chomp` and compare as Strings.
    #
    # @param [Code, Object] other
    # @return [Boolean]
    def ==(other)
      if other.is_a?(Code)
        @other_lines = other.instance_variable_get(:@lines)
        @lines.each_with_index.all? do |(l, ln), i|
          l == @other_lines[i].first && ln == @other_lines[i].last
        end
      else
        to_s.chomp == other.to_s.chomp
      end
    end

    # Forward any missing methods to the output of `#to_s`.
    def method_missing(name, *args, &blk)
      to_s.send(name, *args, &blk)
    end
    undef =~

    protected

    # An abstraction of the `dup.instance_eval` pattern used throughout this
    # class.
    def alter(&blk)
      dup.tap { |o| o.instance_eval(&blk) }
    end

    def add_color(line_tuple)
      line_tuple[0] = CodeRay.scan(line_tuple[0], @code_type).term
    end

    def add_line_numbers(line_tuple)
      max_width = @lines.last.last.to_s.length if @lines.length > 0
      padded_line_num = line_tuple[1].to_s.rjust(max_width || 0)
      line_tuple[0] =
        "#{ Pry::Helpers::BaseHelpers.colorize_code(padded_line_num.to_s) }: " \
        "#{ line_tuple[0] }"
    end

    def add_marker(line_tuple)
      line_tuple[0] = if line_tuple[1] == @marker_line_num
                        " => #{ line_tuple[0] }"
                      else
                        "    #{ line_tuple[0] }"
                      end
    end

    def add_indentation(line_tuple)
      line_tuple[0] = "#{ ' ' * @indentation_num }#{ line_tuple[0] }"
    end

    # If +end_line+ is `nil`, then assign to it +start_line+.
    # @param [Integer, Range] start_line
    # @param [Integer] end_line
    # @return [Array<Integer>]
    def reform_start_and_end_lines(start_line, end_line)
      if start_line.is_a?(Range)
        get_start_and_end_from_range(start_line)
      else
        end_line ||= start_line
        [start_line, end_line]
      end
    end

    # @param [Integer] start_line
    # @param [Integer] end_line
    # @return [Array<Integer>]
    def start_and_end_indices(start_line, end_line)
      return find_start_index(start_line), find_end_index(end_line)
    end

    # @param [Integer] start_line
    # @return [Integer]
    def find_start_index(start_line)
      return start_line if start_line < 0
      @lines.index { |l| l.last >= start_line } || @lines.length
    end

    # @param [Integer] end_line
    # @return [Integer]
    def find_end_index(end_line)
      return end_line if end_line < 0
      (@lines.index { |l| l.last > end_line } || 0) - 1
    end

    # @param [Range] range
    # @return [Array<Integer>]
    def get_start_and_end_from_range(range)
      end_line = range.last
      end_line -= 1 if range.exclude_end?
      [range.first, end_line]
    end
  end
end
