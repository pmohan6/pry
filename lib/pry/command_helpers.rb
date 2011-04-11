class Pry
  class Commands < CommandBase
    module CommandHelpers 

      private
      
      def meth_name_from_binding(b)
        meth_name = b.eval('__method__')
        if [:__script__, nil, :__binding__, :__binding_impl__].include?(meth_name)
          nil
        else
          meth_name
        end
      end

      def set_file_and_dir_locals(file_name)
        return if !target
        $_file_temp = File.expand_path(file_name)
        $_dir_temp =  File.dirname($_file_temp)
        target.eval("_file_ = $_file_temp")
        target.eval("_dir_ = $_file_temp")
      end

      # a simple pager for systems without `less`. A la windows.
      def simple_pager(text)
        page_size = 22
        text_array = text.lines.to_a
        text_array.each_slice(page_size) do |chunk|
          output.puts chunk.join
          break if chunk.size < page_size
          if text_array.size > page_size
            output.puts "\n<page break> --- Press enter to continue ( q<enter> to break ) --- <page break>" 
            break if $stdin.gets.chomp == "q"
          end
        end
      end
      
      def stagger_output(text)
        if RUBY_PLATFORM =~ Regexp.union(/win32/, /mingw32/)
          simple_pager(text)
        else
          lesspipe { |less| less.puts text }
        end
      end
      
      def add_line_numbers(lines, start_line)
        line_array = lines.each_line.to_a
        line_array.each_with_index.map do |line, idx|
          adjusted_index = idx + start_line
          if Pry.color
            cindex = CodeRay.scan("#{adjusted_index}", :ruby).term
            "#{cindex}: #{line}"
          else
            "#{idx}: #{line}"
          end
        end.join
      end

      # only add line numbers if start_line is not false
      # if start_line is not false then add line numbers starting with start_line
      def render_output(should_flood, start_line, doc)
        if start_line
          doc = add_line_numbers(doc, start_line)
        end

        if should_flood
          output.puts doc
        else
          stagger_output(doc)
        end
      end

      def check_for_dynamically_defined_method(meth)
        file, _ = meth.source_location
        if file =~ /(\(.*\))|<.*>/
          raise "Cannot retrieve source for dynamically defined method."
        end
      end

      def remove_first_word(text)
        text.split.drop(1).join(' ')
      end

      def get_method_object(meth_name, target, options)
        if !meth_name
          return nil
        end
        
        if options[:M]
          target.eval("instance_method(:#{meth_name})")
        elsif options[:m]
          target.eval("method(:#{meth_name})")
        else
          begin
            target.eval("instance_method(:#{meth_name})")
          rescue
            begin
              target.eval("method(:#{meth_name})")
            rescue
              return nil
            end
          end
        end
      end
      
      def make_header(meth, code_type)
        file, line = meth.source_location
        case code_type
        when :ruby
          "\nFrom #{file} @ line #{line}:\n\n"
        else
          "\nFrom Ruby Core (C Method):\n\n"
        end
      end

      def is_a_c_method?(meth)
        meth.source_location.nil?
      end

      def should_use_pry_doc?(meth)
        Pry.has_pry_doc && is_a_c_method?(meth)
      end
      
      def code_type_for(meth)
        # only C methods
        if should_use_pry_doc?(meth)
          info = Pry::MethodInfo.info_for(meth) 
          if info && info.source
            code_type = :c
          else
            output.puts "Cannot find C method: #{meth.name}"
            code_type = nil
          end
        else
          if is_a_c_method?(meth)
            output.puts "Cannot locate this method: #{meth.name}. Try `gem install pry-doc` to get access to Ruby Core documentation."
            code_type = nil
          else
            check_for_dynamically_defined_method(meth)
            code_type = :ruby
          end
        end
        code_type
      end
      
      def file_map
        {
          [".c", ".h"] => :c,
          [".cpp", ".hpp", ".cc", ".h", "cxx"] => :cpp,
          [".rb", "Rakefile"] => :ruby,
          ".py" => :python,
          ".diff" => :diff,
          ".css" => :css,
          ".html" => :html,
          [".yaml", ".yml"] => :yaml,
          ".xml" => :xml,
          ".php" => :php,
          ".js" => :javascript,
          ".java" => :java,
          ".rhtml" => :rhtml,
          ".json" => :json
        }
      end
      
      def syntax_highlight_by_file_type_or_specified(contents, file_name, file_type)
        _, language_detected = file_map.find do |k, v|
          Array(k).any? do |matcher|
            matcher == File.extname(file_name) || matcher == File.basename(file_name)
          end
        end

        language_detected = file_type if file_type
        CodeRay.scan(contents, language_detected).term
      end

      # convert negative line numbers to positive by wrapping around
      # last line (as per array indexing with negative numbers)
      def normalized_line_number(line_number, total_lines)
        line_number < 0 ? line_number + total_lines : line_number
      end
      
      # returns the file content between the lines and the normalized
      # start and end line numbers.
      def read_between_the_lines(file_name, start_line, end_line)
        content = File.read(File.expand_path(file_name))
        lines_array = content.each_line.to_a

        [lines_array[start_line..end_line].join, normalized_line_number(start_line, lines_array.size),
         normalized_line_number(end_line, lines_array.size)]
      end

      # documentation related helpers
      def strip_color_codes(str)
        str.gsub(/\e\[.*?(\d)+m/, '')
      end

      def process_rdoc(comment, code_type)
        comment = comment.dup
        comment.gsub(/<code>(?:\s*\n)?(.*?)\s*<\/code>/m) { Pry.color ? CodeRay.scan($1, code_type).term : $1 }.
          gsub(/<em>(?:\s*\n)?(.*?)\s*<\/em>/m) { Pry.color ? "\e[32m#{$1}\e[0m": $1 }.
          gsub(/<i>(?:\s*\n)?(.*?)\s*<\/i>/m) { Pry.color ? "\e[34m#{$1}\e[0m" : $1 }.
          gsub(/\B\+(\w*?)\+\B/)  { Pry.color ? "\e[32m#{$1}\e[0m": $1 }.
          gsub(/((?:^[ \t]+.+(?:\n+|\Z))+)/)  { Pry.color ? CodeRay.scan($1, code_type).term : $1 }.
          gsub(/`(?:\s*\n)?(.*?)\s*`/) { Pry.color ? CodeRay.scan($1, code_type).term : $1 }
      end

      def process_yardoc_tag(comment, tag)
        in_tag_block = nil
        output = comment.lines.map do |v|
          if in_tag_block && v !~ /^\S/
            strip_color_codes(strip_color_codes(v))
          elsif in_tag_block
            in_tag_block = false
            v
          else
            in_tag_block = true if v =~ /^@#{tag}/
            v
          end
        end.join
      end

      def process_yardoc(comment)
        yard_tags = ["param", "return", "option", "yield", "attr", "attr_reader", "attr_writer",
                     "deprecate", "example"]
        (yard_tags - ["example"]).inject(comment) { |a, v| process_yardoc_tag(a, v) }.
          gsub(/^@(#{yard_tags.join("|")})/) { Pry.color ? "\e[33m#{$1}\e[0m": $1 }
      end

      def process_comment_markup(comment, code_type)
        process_yardoc process_rdoc(comment, code_type)
      end

      # strip leading whitespace but preserve indentation
      def strip_leading_whitespace(text)
        return text if text.empty?
        leading_spaces = text.lines.first[/^(\s+)/, 1]
        text.gsub(/^#{leading_spaces}/, '')
      end

      def strip_leading_hash_and_whitespace_from_ruby_comments(comment)
        comment = comment.dup
        comment.gsub!(/\A\#+?$/, '')
        comment.gsub!(/^\s*#/, '')
        strip_leading_whitespace(comment)
      end

      def strip_comments_from_c_code(code)
        code.sub /\A\s*\/\*.*?\*\/\s*/m, ''
      end

      # thanks to epitron for this method
      def lesspipe(*args)
        if args.any? and args.last.is_a?(Hash)
          options = args.pop
        else
          options = {}
        end
        
        output = args.first if args.any?
        
        params = []
        params << "-R" unless options[:color] == false
        params << "-S" unless options[:wrap] == true
        params << "-F" unless options[:always] == true
        if options[:tail] == true
          params << "+\\>"
          $stderr.puts "Seeking to end of stream..."
        end
        params << "-X"
        
        IO.popen("less #{params * ' '}", "w") do |less|
          if output
            less.puts output
          else
            yield less
          end
        end
      end      

    end
  end
end
