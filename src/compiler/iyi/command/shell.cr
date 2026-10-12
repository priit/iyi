# A native compiled shell: use exactly the same compiler and runtime as `run`.
# Like koja's initial shell, successful input blocks accumulate and the whole
# session is executed again. There is no second implementation of iyi semantics.
# Many thanks to Henry Popp, Koja's creator, for the inspiration:
# https://github.com/koja-lang/koja/tree/main/crates/koja-shell
require "file_utils"
require "random/secure"

class Iyi::Command
  private def shell
    preload = nil
    auto_print = true
    while option = options.shift?
      case option
      when "--preload"
        value = options.shift?
        abort! "shell: --preload takes an .iyi file", :USAGE_ERROR unless value && !value.empty? && !value.starts_with?('-')
        abort! "shell: --preload can only be specified once", :USAGE_ERROR if preload
        abort! "shell: #{value} is not an .iyi file", :USAGE_ERROR unless value.ends_with?(".iyi")
        abort! "shell: no such file: #{value}", :USAGE_ERROR unless File.file?(value)
        preload = File.expand_path(value)
      when "--no-print"
        auto_print = false
      when "--help", "-h"
        puts shell_usage
        exit
      else
        abort! "shell: unexpected argument #{option}; run `#{Command.program_name} shell --help`", :USAGE_ERROR
      end
    end

    executable = Process.executable_path || abort! "shell: cannot locate the compiler executable", :USAGE_ERROR
    baseline = preload ? File.read(preload) : "module iyi_shell_session\n"
    abort! "shell: preload must be valid UTF-8 source", :USAGE_ERROR unless baseline.valid_encoding?
    # A virtual filename beside the project lets the normal import resolver
    # find local modules and iyi.mod. Source and executables live only in a
    # private temporary directory; nothing is written into the user's project.
    filename = File.join(Dir.current, "iyi_shell_session.iyi")
    session = Iyi::Shell::Session.new(baseline, filename, auto_print)
    scratch_path = File.tempname("iyi-shell")
    Dir.mkdir(scratch_path, 0o700)
    scratch = scratch_path
    output = File.join(scratch, "session#{::Path[executable].extension == ".exe" ? ".exe" : ""}")
    interactive = STDIN.tty?
    if interactive
      print Iyi::Shell.banner(Dir.current, @color)
    else
      puts Iyi::Shell::NOTICE
    end

    pending = ""
    line_number = 1
    loop do
      if interactive
        print Iyi::Shell.prompt(line_number, !pending.empty?)
        STDOUT.flush
      end
      line = STDIN.gets
      unless line
        STDERR.puts "shell: incomplete input discarded at EOF" unless pending.empty?
        break
      end
      line_number += 1
      unless line.valid_encoding?
        STDERR.puts "shell: input must be valid UTF-8 source"
        pending = ""
        next
      end
      command = line.strip
      # A reset inside a multiline block discards just that pending block,
      # as in koja. At a fresh prompt it clears the successful history.
      case command
      when ":reset"
        if pending.empty?
          session.clear
          line_number = 1
        else
          pending = ""
        end
        next
      when ":quit", ":q"
        break
      when "exit"
        break if pending.empty?
      when ":help"
        puts shell_usage
        next
      when ":state"
        puts "session: #{session.size} input block(s)"
        next
      end
      next if pending.empty? && command.empty?
      pending += line + "\n"
      next if session.incomplete?(pending)

      source = session.source(pending)
      status = Process.run(executable,
        ["build", "--stdin-filename", filename, "-o", output],
        env: {"IYI_OPTS" => nil, "CRYSTAL_OPTS" => nil},
        input: IO::Memory.new(source), output: STDOUT, error: STDERR)
      if status.success?
        # A submitted program must not consume subsequent shell commands.
        status = Process.run(output, input: Process::Redirect::Close,
          output: STDOUT, error: STDERR)
        if status.success?
          session.accept(pending)
        else
          STDERR.puts "shell: program exited with #{status.exit_code}; input was not retained"
        end
      end
      pending = ""
    end
  rescue ex : IO::Error | File::Error
    abort! "shell: #{ex.message}", :USAGE_ERROR
  ensure
    if scratch
      FileUtils.rm_rf(scratch)
    end
  end

  private def shell_usage : String
    <<-USAGE
      Usage: #{Command.program_name} shell [--preload FILE.iyi] [--no-print]

      Native compiled shell, using the current directory's imports and iyi.mod.
      Each input recompiles and reruns the entire session, including side effects.
      :reset clears input history; it does not undo external changes. A preload
      remains in scope after reset and runs again with every submitted input.
      Failed inputs are not retained; their external side effects are not undone.

      --preload FILE.iyi  start with a complete iyi source file (module and imports)
      --no-print         use explicit puts instead of printing trailing expressions

      :help   show this help
      :state  show the number of retained input blocks
      :reset  start a new session, or discard a pending multiline input
      :quit   exit (also :q, bare exit at a fresh prompt, or EOF)

      Multiline blocks, brackets and strings continue until complete. Submitted
      programs receive closed stdin; stdin is reserved for shell commands.
      USAGE
  end
end

module Iyi::Shell
  NOTICE = "Each input reruns the whole session and :reset starts fresh."

  def self.banner(directory : String, color : Bool = false) : String
    home = ::Path.home.to_s
    # Only abbreviate a complete home-directory component, not a similar prefix.
    directory = if directory == home
                  "~"
                elsif directory.starts_with?(home + ::File::SEPARATOR)
                  "~" + directory[home.size..]
                else
                  directory
                end
    top = "  +-----+".colorize(:blue).toggle(color).to_s
    middle = "  | iyi |".colorize(:blue).toggle(color).to_s
    bottom = "  +-----+".colorize(:blue).toggle(color).to_s
    "#{top}  iyi shell v#{Config.iyi_version}\n" +
      "#{middle}  \":help\" for commands, \":q\" or \"exit\" to quit\n" +
      "#{bottom}  #{directory}\n\n#{NOTICE}\n\n"
  end

  def self.prompt(line_number : Int32, continuation : Bool) : String
    "iyi(main):#{line_number.to_s.rjust(3, '0')}#{continuation ? '*' : '>'} "
  end

  class Session
    @statements = [] of String

    def initialize(@baseline : String, @filename : String, @auto_print : Bool = true)
      @result_name = "__iyi_shell_result_#{Random::Secure.hex(8)}"
    end

    def size : Int32
      @statements.size
    end

    def clear : Nil
      @statements.clear
    end

    def accept(input : String) : Nil
      @statements << input
    end

    private def raw_source(input : String) : String
      @baseline + "\n" + @statements.join("\n") + "\n" + input + "\n"
    end

    private def parser(source : String) : Parser
      parser = Parser.new(source)
      parser.filename = @filename
      parser
    end

    def incomplete?(input : String) : Bool
      parser = parser(raw_source(input))
      parser.parse
      false
    rescue ex : SyntaxException
      message = ex.message || ""
      (parser.try(&.token.type.eof?) || false) || (message.starts_with?("unterminated") && !message.includes?("use double quotes"))
    end

    def source(input : String) : String
      source = raw_source(input)
      return source unless @auto_print
      node = parser(source).parse
      # Native parsing returns the header and a synthetic compilation-unit
      # ModuleDef. Unwrap that scope, but never a user-declared module.
      node = node.expressions.last if node.is_a?(Expressions)
      if node.is_a?(ModuleDef) && node.iyi_unit?
        node = node.body
      end
      last = node.is_a?(Expressions) ? node.expressions.last : node
      # Declarations and assignments stay at module scope. For expressions,
      # print through the actual native runtime, evaluating the last one once.
      case last
      when NumberLiteral, StringLiteral, BoolLiteral, NilLiteral, CharLiteral,
           SymbolLiteral, ArrayLiteral, HashLiteral, TupleLiteral, NamedTupleLiteral,
           RegexLiteral, Var, Path, Call, If, Case, RangeLiteral, Not, And, Or,
           Recover, Propagate, Expressions, IsA, RespondsTo, Cast, NilableCast,
           PointerOf, SizeOf, InstanceSizeOf, TypeOf
        if location = last.location
          lines = source.lines(chomp: false)
          prefix = lines[0, location.line_number - 1].join
          prefix += lines[location.line_number - 1][0, location.column_number - 1]
          return source if prefix.size < source.size - input.size - 1
          expression = source[prefix.size..]
          return prefix + "#{@result_name} = begin\n#{expression}\nend\n" +
            "puts #{@result_name} unless #{@result_name}.nil?\n"
        end
      end
      source
    rescue SyntaxException
      # The build produces the ordinary source diagnostic, with its location.
      raw_source(input)
    end
  end
end
