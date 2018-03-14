# lib/trollop.rb -- trollop command-line processing library
# Copyright (c) 2008-2014 William Morgan.
# Copyright (c) 2014 Red Hat, Inc.
# trollop is licensed under the MIT license.

require 'date'

module Trollop
  # note: this is duplicated in gemspec
  # please change over there too
VERSION = "2.1.2"

## Thrown by Parser in the event of a commandline error. Not needed if
## you're using the Trollop::options entry.
class CommandlineError < StandardError
  attr_reader :error_code

  def initialize(msg, error_code = nil)
    super(msg)
    @error_code = error_code
  end
end

## Thrown by Parser if the user passes in '-h' or '--help'. Handled
## automatically by Trollop#options.
class HelpNeeded < StandardError
end

## Thrown by Parser if the user passes in '-v' or '--version'. Handled
## automatically by Trollop#options.
class VersionNeeded < StandardError
end

# Regex for floating point numbers
FLOAT_RE = /^-?((\d+(\.\d+)?)|(\.\d+))([eE][-+]?[\d]+)?$/ #:nodoc:

# Regex for parameters
PARAM_RE = /^-(-|\.$|[^\d\.])/ #:nodoc:

class Option

  attr_accessor :long, :short, :name, :multi_given, :hidden, :default
  
  def initialize
    @long = nil
    @short = nil
    @name = nil
    @multi_given = false
    @hidden = false
    @default = nil
    @optshash = Hash.new()
  end
  def opts (key)
    @optshash[key]
  end

  def opts= (o)
    @optshash = o
  end
  
  ## Indicates a flag option, which is an option without an argument
  def flag? ; false ; end
  ## Indicates that this is a multivalued (Array type) argument
  def multi? ; false ; end
  ## note: Option-Types with both multi? and flag? false are single-parameter (normal) options.

  def parse (_paramlist, _neg_given)
    raise NotImplementedError, "parse must be overridden for newly registered type"
  end

  # provide education string.  default to empty, but user should probably override it
  def educate ; "" ; end
  
  def short? ; short && short != :none ; end
  def desc ; opts(:desc) ; end
  def required? ; opts(:required) ; end
  def callback ; opts(:callback) ; end
  def multi_given? ; self.multi_given ; end
  def single_arg? ; !self.multi? and !self.flag? ; end
  def multi_arg? ; self.multi? ; end
  def array_default? ; self.default.kind_of?(Array) ; end

  ## Format the educate-line description including the default-value(s)
  def format_description
    return desc unless default
    defstring = begin
                  default_s = case default
                              when $stdout   then "<stdout>"
                              when $stdin    then "<stdin>"
                              when $stderr   then "<stderr>"
                              when Array
                                default.join(", ")
                              else
                                default.to_s
                              end
                  
                  if desc =~ /\.$/
                    " (Default: #{default_s})"
                  else
                    " (default: #{default_s})"
                  end
                end
    return desc + defstring
    
  end
end

# Flag option.  Has no arguments. Can be negated with "no-".
class BooleanOption < Option
  def initialize
    super()
    @default = false
  end

  def flag? ; true ; end
  def parse(_paramlist, neg_given)
    return(self.name.to_s =~ /^no_/ ? neg_given : !neg_given)
  end
end

# Floating point number option class.
class FloatOption < Option
  def educate ; "=<f>" ; end
  def parse(paramlist, _neg_given)
    paramlist.map do |pg|
      pg.map do |param|
        raise CommandlineError, "option '#{self.name}' needs a floating-point number" unless param =~ FLOAT_RE
        param.to_f
      end
    end
  end
end

# Integer number option class.
class IntegerOption < Option
  def educate ; "=<i>" ; end
  def parse(paramlist, _neg_given)
    paramlist.map do |pg|
      pg.map do |param|
        raise CommandlineError, "option '#{self.name}' needs an integer" unless param =~ /^-?[\d_]+$/
        param.to_i
      end
    end
  end
end

# Option class for handling IO objects and URLs.
# Note that this will return the file-handle, not the file-name
# in the case of file-paths given to it.
class IOOption < Option
  def educate ; "=<filename/uri>" ; end
  def parse(paramlist, _neg_given)
    paramlist.map do |pg|
      pg.map do |param|
        if param =~ /^(stdin|-)$/i
          $stdin
        else
          require 'open-uri'
          begin
            open param
          rescue SystemCallError => e
            raise CommandlineError, "file or url for option '#{self.name}' cannot be opened: #{e.message}"
          end
        end
      end
    end
  end
end

# Option class for handling Strings.
class StringOption < Option
  def educate ; "=<s>" ; end
  def parse(paramlist, _neg_given)
    paramlist.map { |pg| pg.map(&:to_s) }
  end
end

# Option for dates.  Uses Chronic if it exists.
class DateOption < Option
  def educate ; "=<date>" ; end
  def parse(paramlist, _neg_given)
    paramlist.map do |pg|
      pg.map do |param|
        begin
          begin
            require 'chronic'
            time = Chronic.parse(param)
          rescue LoadError
            # chronic is not available
          end
          time ? Date.new(time.year, time.month, time.day) : Date.parse(param)
        rescue ArgumentError
          raise CommandlineError, "option '#{self.name}' needs a date"
        end
      end
    end
  end
end
### MULTI_OPT_TYPES :
## The set of values that indicate a multiple-parameter option (i.e., that
## takes multiple space-separated values on the commandline) when passed as
## the +:type+ parameter of #opt.

# Option class for handling multiple Integers
class IntegerArrayOption < IntegerOption
  def educate ; "=<i+>" ; end
  def multi? ; true ; end
end

# Option class for handling multiple Floats
class FloatArrayOption < FloatOption
  def educate ; "=<f+>" ; end
  def multi? ; true ; end
end

# Option class for handling multiple Strings
class StringArrayOption < StringOption
  def educate ; "=<s+>" ; end
  def multi? ; true ; end
end

# Option class for handling multiple dates
class DateArrayOption < DateOption
  def educate ; "=<date+>" ; end
  def multi? ; true ; end
end

# Option class for handling Files/URLs via 'open'
class IOArrayOption < IOOption
  def educate ; "=<filename/uri+>" ; end
  def multi? ; true ; end
end

## The commandline parser. In typical usage, the methods in this class
## will be handled internally by Trollop::options. In this case, only the
## #opt, #banner and #version, #depends, and #conflicts methods will
## typically be called.
##
## If you want to instantiate this class yourself (for more complicated
## argument-parsing logic), call #parse to actually produce the output hash,
## and consider calling it from within
## Trollop::with_standard_exception_handling.
class Parser
  
  ## The registry is a class-variable Hash of registered option types.
  ## By default, it contains flag(boolean), int, float, string, io and date types
  ## and their plural versions.
  ## This can be updated by the user to include custom types
  
  @@registry = {
    # single-opt
    :fixnum => IntegerOption,
    :int => IntegerOption,
    :integer => IntegerOption,
    :float => FloatOption,
    :double => FloatOption,
    :string => StringOption,
    :bool => BooleanOption,
    :boolean => BooleanOption,
    :flag => BooleanOption,
    :io => IOOption,
    :date => DateOption,
    :trueclass => BooleanOption,
    :falseclass => BooleanOption,
    ## multi-opt
    :fixnums => IntegerArrayOption,
    :ints => IntegerArrayOption,
    :integers => IntegerArrayOption,
    :doubles => FloatArrayOption,
    :floats => FloatArrayOption,
    :strings => StringArrayOption,
    :dates => DateArrayOption,
    :ios => IOArrayOption,
  }
  ## Register an additional type to an particular class.
  ## The optType class should inherit from Option
  def self.register type, klass
    raise "Registered class #{klass.name} should inherit from Option, ancestors were #{klass.ancestors}" unless klass.ancestors.include? Option
    @@registry[type] = klass
  end
  def self.registry_include?(type)
    @@registry.has_key?(type)
  end
  ## Formerly, the complete set of legal values for the +:type+ parameter of #opt.
  def self.registry_types
    @@registry.keys
  end

  ## Gets the class from the registry.
  ## Can be given either a class-name, e.g. Integer, a string, e.g "integer", or a symbol, e.g :integer
  def self.registry_getklass(type)
    return nil unless type
    if type.respond_to?(:name)
      type = type.name
      lookup = type.downcase.to_sym
    else
      lookup = type.to_sym
    end
    raise ArgumentError, "Unsupported argument type '#{type}', registry lookup '#{lookup}'" unless @@registry.has_key?(lookup)
    return @@registry[lookup]
  end
  
  def self.registry_getopttype(type)
    klass_or_nil = self.registry_getklass(type)
    return nil unless klass_or_nil
    return klass_or_nil.new
  end

  INVALID_SHORT_ARG_REGEX = /[\d-]/ #:nodoc:

  ## The values from the commandline that were not interpreted by #parse.
  attr_reader :leftovers

  ## The complete configuration hashes for each option. (Mainly useful
  ## for testing.)
  attr_reader :specs

  ## A flag that determines whether or not to raise an error if the parser is passed one or more
  ##  options that were not registered ahead of time.  If 'true', then the parser will simply
  ##  ignore options that it does not recognize.
  attr_accessor :ignore_invalid_options

  ## Initializes the parser, and instance-evaluates any block given.
  ## Arguments attempt to be interpreted as a Hash
  def initialize(*a, &b)
    @version = nil
    @leftovers = []
    @specs = {}
    @long = {}
    @short = {}
    @order = []
    @constraints = []
    @stop_words = []
    @stop_on_unknown = false
    @educate_on_error = false
    @synopsis = nil
    @usage = nil
    
    ## allow passing settings through Parser.new as an optional hash.
    ## but keep compatibility with non-hashy args, though.
    begin
      @settings = Hash[*a]
      a=[] ## clear out args if using as settings-hash
    rescue ArgumentError
      @settings = Hash.new()
    end

    # instance_eval(&b) if b # can't take arguments
    #cloaker(&b).bind(self).call(*a) if b
    self.instance_exec(*a,&b) if block_given?
  end

  ## Define an option. +name+ is the option name, a unique identifier
  ## for the option that you will use internally, which should be a
  ## symbol or a string. +desc+ is a string description which will be
  ## displayed in help messages.
  ##
  ## Takes the following optional arguments:
  ##
  ## [+:long+] Specify the long form of the argument, i.e. the form with two dashes. If unspecified, will be automatically derived based on the argument name by turning the +name+ option into a string, and replacing any _'s by -'s.
  ## [+:short+] Specify the short form of the argument, i.e. the form with one dash. If unspecified, will be automatically derived from +name+. Use :none: to not have a short value.
  ## [+:type+] Require that the argument take a parameter or parameters of type +type+. For a single parameter, the value can be a member of +SINGLE_ARG_TYPES+, or a corresponding Ruby class (e.g. +Integer+ for +:int+). For multiple-argument parameters, the value can be any member of +MULTI_ARG_TYPES+ constant. If unset, the default argument type is +:flag+, meaning that the argument does not take a parameter. The specification of +:type+ is not necessary if a +:default+ is given.
  ## [+:default+] Set the default value for an argument. Without a default value, the hash returned by #parse (and thus Trollop::options) will have a +nil+ value for this key unless the argument is given on the commandline. The argument type is derived automatically from the class of the default value given, so specifying a +:type+ is not necessary if a +:default+ is given. (But see below for an important caveat when +:multi+: is specified too.) If the argument is a flag, and the default is set to +true+, then if it is specified on the the commandline the value will be +false+.
  ## [+:required+] If set to +true+, the argument must be provided on the commandline.
  ## [+:multi+] If set to +true+, allows multiple occurrences of the option on the commandline. Otherwise, only a single instance of the option is allowed. (Note that this is different from taking multiple parameters. See below.)
  ##
  ## Note that there are two types of argument multiplicity: an argument
  ## can take multiple values, e.g. "--arg 1 2 3". An argument can also
  ## be allowed to occur multiple times, e.g. "--arg 1 --arg 2".
  ##
  ## Arguments that take multiple values should have a +:type+ parameter
  ## drawn from +MULTI_ARG_TYPES+ (e.g. +:strings+), or a +:default:+
  ## value of an array of the correct type (e.g. [String]). The
  ## value of this argument will be an array of the parameters on the
  ## commandline.
  ##
  ## Arguments that can occur multiple times should be marked with
  ## +:multi+ => +true+. The value of this argument will also be an array.
  ## In contrast with regular non-multi options, if not specified on
  ## the commandline, the default value will be [], not nil.
  ##
  ## These two attributes can be combined (e.g. +:type+ => +:strings+,
  ## +:multi+ => +true+), in which case the value of the argument will be
  ## an array of arrays.
  ##
  ## There's one ambiguous case to be aware of: when +:multi+: is true and a
  ## +:default+ is set to an array (of something), it's ambiguous whether this
  ## is a multi-value argument as well as a multi-occurrence argument.
  ## In thise case, Trollop assumes that it's not a multi-value argument.
  ## If you want a multi-value, multi-occurrence argument with a default
  ## value, you must specify +:type+ as well.

  def opt(name, desc = "", opts = {}, &b)
    opts[:callback] ||= b if block_given?
    opts[:desc] ||= desc

    o = OptionDispatch.create(name, desc, opts, @settings)

    raise ArgumentError, "you already have an argument named '#{name}'" if @specs.member? o.name
    raise ArgumentError, "long option name #{o.long.inspect} is already taken; please specify a (different) :long" if @long[o.long]
    raise ArgumentError, "short option name #{o.short.inspect} is already taken; please specify a (different) :short" if @short[o.short]
    @long[o.long] = o.name
    @short[o.short] = o.name if o.short?
    @specs[o.name] = o
    @order << [:opt, o.name]
  end

  ## Sets the version string. If set, the user can request the version
  ## on the commandline. Should probably be of the form "<program name>
  ## <version number>".
  def version(s = nil)
    s ? @version = s : @version
  end

  ## Sets the usage string. If set the message will be printed as the
  ## first line in the help (educate) output and ending in two new
  ## lines.
  def usage(s = nil)
    s ? @usage = s : @usage
  end

  ## Adds a synopsis (command summary description) right below the
  ## usage line, or as the first line if usage isn't specified.
  def synopsis(s = nil)
    s ? @synopsis = s : @synopsis
  end

  ## Adds text to the help display. Can be interspersed with calls to
  ## #opt to build a multi-section help page.
  def banner(s)
    @order << [:text, s]
  end
  alias_method :text, :banner

  ## Marks two (or more!) options as requiring each other. Only handles
  ## undirected (i.e., mutual) dependencies. Directed dependencies are
  ## better modeled with Trollop::die.
  def depends(*syms)
    syms.each { |sym| raise ArgumentError, "unknown option '#{sym}'" unless @specs[sym] }
    @constraints << [:depends, syms]
  end

  ## Marks two (or more!) options as conflicting.
  def conflicts(*syms)
    syms.each { |sym| raise ArgumentError, "unknown option '#{sym}'" unless @specs[sym] }
    @constraints << [:conflicts, syms]
  end

  ## Defines a set of words which cause parsing to terminate when
  ## encountered, such that any options to the left of the word are
  ## parsed as usual, and options to the right of the word are left
  ## intact.
  ##
  ## A typical use case would be for subcommand support, where these
  ## would be set to the list of subcommands. A subsequent Trollop
  ## invocation would then be used to parse subcommand options, after
  ## shifting the subcommand off of ARGV.
  def stop_on(*words)
    @stop_words = [*words].flatten
  end

  ## Similar to #stop_on, but stops on any unknown word when encountered
  ## (unless it is a parameter for an argument). This is useful for
  ## cases where you don't know the set of subcommands ahead of time,
  ## i.e., without first parsing the global options.
  def stop_on_unknown
    @stop_on_unknown = true
  end

  ## Instead of displaying "Try --help for help." on an error
  ## display the usage (via educate)
  def educate_on_error
    @educate_on_error = true
  end

  ## Match long variables with inexact match.
  ## If we hit a complete match, then use that, otherwise see how many long-options partially match.
  ## If only one partially matches, then we can safely use that.
  ## Otherwise, we raise an error that the partially given option was ambiguous.
  def perform_inexact_match (arg, partial_match)  # :nodoc:
    return @long[partial_match] if @long.has_key?(partial_match)
    partially_matched_keys = @long.keys.grep(/^#{partial_match}/)
    return case partially_matched_keys.size
           when 0 ; nil
           when 1 ; @long[partially_matched_keys.first]
           else ; raise CommandlineError, "ambiguous option '#{arg}' matched keys (#{partially_matched_keys.join(',')})"
           end
  end
  private :perform_inexact_match

  def handle_unknown_argument(arg, candidates, suggestions)
    errstring = "unknown argument '#{arg}'"
    if suggestions and  Module::const_defined?("DidYouMean::JaroWinkler") and Module::const_defined?("DidYouMean::Levenshtein")
      input = arg.sub(/^[-]*/,'')
      #require 'did_you_mean'
      # Code borrowed from did_you_mean gem
      jw_threshold = 0.75
      seed = candidates.select {|candidate| DidYouMean::JaroWinkler.distance(candidate, input) >= jw_threshold }
               .sort_by! {|candidate| DidYouMean::JaroWinkler.distance(candidate.to_s, input) }
               .reverse!
      # Correct mistypes
      threshold   = (input.length * 0.25).ceil
      has_mistype = seed.rindex {|c| DidYouMean::Levenshtein.distance(c, input) <= threshold }
      corrections = if has_mistype
                      seed.take(has_mistype + 1)
                    else
                      # Correct misspells
                      seed.select do |candidate|
                        length    = input.length < candidate.length ? input.length : candidate.length

                        DidYouMean::Levenshtein.distance(candidate, input) < length
                      end.first(1)
                    end
      unless corrections.empty?
        dashdash_corrections = corrections.map{|s| "--#{s}" }
        errstring << ".  Did you mean: [#{dashdash_corrections.join(', ')}] ?"
      end
    end
    raise CommandlineError, errstring 
  end
  private :handle_unknown_argument
        
  ## Parses the commandline. Typically called by Trollop::options,
  ## but you can call it directly if you need more control.
  ##
  ## throws CommandlineError, HelpNeeded, and VersionNeeded exceptions.
  def parse(cmdline = ARGV)
    vals = {}
    required = {}

    opt :version, "Print version and exit" if @version && ! (@specs[:version] || @long["version"])
    opt :help, "Show this message" unless @specs[:help] || @long["help"]

    @specs.each do |sym, opts|
      required[sym] = true if opts.required?
      vals[sym] = opts.default
      vals[sym] = [] if opts.multi_given? && !opts.default # multi arguments default to [], not nil
    end

    resolve_default_short_options! unless @settings[:disable_auto_short_opts]

    ## resolve symbols
    given_args = {}
    @leftovers = each_arg cmdline do |arg, params|
      ## handle --no- forms
      arg, negative_given = if arg =~ /^--no-([^-]\S*)$/
        ["--#{$1}", true]
      else
        [arg, false]
      end

      sym = case arg
        when /^-([^-])$/      then @short[$1]
        when /^--([^-]\S*)$/  then @long[$1] || @long["no-#{$1}"]
        else                       raise CommandlineError, "invalid argument syntax: '#{arg}'"
      end

      sym = nil if arg =~ /--no-/ # explicitly invalidate --no-no- arguments

      ## Support inexact matching of long-arguments like perl's Getopt::Long
      if @settings[:inexact_match] and arg.match(/^--(\S*)$/)
        sym = perform_inexact_match(arg, $1)
      end
      
      next nil if ignore_invalid_options && !sym
      handle_unknown_argument(arg, @long.keys, @settings[:suggestions]) unless sym

      if given_args.include?(sym) && !@specs[sym].multi_given?
        raise CommandlineError, "option '#{arg}' specified multiple times"
      end

      given_args[sym] ||= {}
      given_args[sym][:arg] = arg
      given_args[sym][:negative_given] = negative_given
      given_args[sym][:params] ||= []

      # The block returns the number of parameters taken.
      num_params_taken = 0

      unless params.empty?
        if @specs[sym].single_arg?
          given_args[sym][:params] << params[0, 1]  # take the first parameter
          num_params_taken = 1
        elsif @specs[sym].multi_arg?
          given_args[sym][:params] << params        # take all the parameters
          num_params_taken = params.size
        end
      end

      num_params_taken
    end

    ## check for version and help args
    raise VersionNeeded if given_args.include? :version
    raise HelpNeeded if given_args.include? :help

    ## check constraint satisfaction
    @constraints.each do |type, syms|
      constraint_sym = syms.find { |sym| given_args[sym] }
      next unless constraint_sym

      case type
      when :depends
        syms.each { |sym| raise CommandlineError, "--#{@specs[constraint_sym].long} requires --#{@specs[sym].long}" unless given_args.include? sym }
      when :conflicts
        syms.each { |sym| raise CommandlineError, "--#{@specs[constraint_sym].long} conflicts with --#{@specs[sym].long}" if given_args.include?(sym) && (sym != constraint_sym) }
      end
    end

    required.each do |sym, val|
      raise CommandlineError, "option --#{@specs[sym].long} must be specified" unless given_args.include? sym
    end

    ## parse parameters
    given_args.each do |sym, given_data|
      arg, params, negative_given = given_data.values_at :arg, :params, :negative_given

      opts = @specs[sym]
      if params.empty? && !opts.flag?
        raise CommandlineError, "option '#{arg}' needs a parameter" unless opts.default
        params << (opts.array_default? ? opts.default.clone : [opts.default])
      end

      vals["#{sym}_given".intern] = true # mark argument as specified on the commandline

      #if opts.type == :flag
      #  vals[sym] = (sym.to_s =~ /^no_/ ? negative_given : !negative_given)
      #else
      #  vals[sym] = opts.parse(params, arg)
      #end

      vals[sym] = opts.parse(params, negative_given)

      if opts.single_arg?
        if opts.multi_given?        # multiple options, each with a single parameter
          vals[sym] = vals[sym].map { |p| p[0] }
        else                  # single parameter
          vals[sym] = vals[sym][0][0]
        end
      elsif opts.multi_arg? && !opts.multi_given?
        vals[sym] = vals[sym][0]  # single option, with multiple parameters
      end
      # else: multiple options, with multiple parameters

      opts.callback.call(vals[sym]) if opts.callback
    end

    ## modify input in place with only those
    ## arguments we didn't process
    cmdline.clear
    @leftovers.each { |l| cmdline << l }

    ## allow openstruct-style accessors
    class << vals
      def method_missing(m, *_args)
        self[m] || self[m.to_s]
      end
    end
    vals
  end

  ## Print the help message to +stream+.
  def educate(stream = $stdout)
    width # hack: calculate it now; otherwise we have to be careful not to
          # call this unless the cursor's at the beginning of a line.
    left = {}
    @specs.each do |name, spec|
      type_edu = spec.educate
      left[name] = (spec.short? ? "-#{spec.short}, " : "") + "--#{spec.long}" + type_edu + (spec.flag? && spec.default ? ", --no-#{spec.long}" : "")
    end

    leftcol_width = left.values.map(&:length).max || 0
    rightcol_start = leftcol_width + 6 # spaces

    unless @order.size > 0 && @order.first.first == :text
      command_name = File.basename($0).gsub(/\.[^.]+$/, '')
      stream.puts "Usage: #{command_name} #{@usage}\n" if @usage
      stream.puts "#{@synopsis}\n" if @synopsis
      stream.puts if @usage || @synopsis
      stream.puts "#{@version}\n" if @version
      stream.puts "Options:"
    end

    @order.each do |what, opt|
      if what == :text
        stream.puts wrap(opt)
        next
      end

      spec = @specs[opt]
      next if spec.hidden
      stream.printf "  %-#{leftcol_width}s    ", left[opt]
      desc = spec.format_description
#      desc = spec.desc + begin
#        default_s = case spec.default
#        when $stdout   then "<stdout>"
#        when $stdin    then "<stdin>"
#        when $stderr   then "<stderr>"
#        when Array
#          spec.default.join(", ")
#        else
#          spec.default.to_s
#        end
#
#        if spec.default
#          if spec.desc =~ /\.$/
#            " (Default: #{default_s})"
#          else
#            " (default: #{default_s})"
#          end
#        else
#          ""
#        end
#      end
      stream.puts wrap(desc, :width => width - rightcol_start - 1, :prefix => rightcol_start)
    end
  end

  def width #:nodoc:
    @width ||= if $stdout.tty?
      begin
        require 'io/console'
        w = IO.console.winsize.last
        w.to_i > 0 ? w : 80
      rescue LoadError, NoMethodError, Errno::ENOTTY, Errno::EBADF, Errno::EINVAL
        legacy_width
      end
    else
      80
    end
  end

  def legacy_width
    # Support for older Rubies where io/console is not available
    `tput cols`.to_i
  rescue Errno::ENOENT
    80
  end
  private :legacy_width

  def wrap(str, opts = {}) # :nodoc:
    if str == ""
      [""]
    else
      inner = false
      str.split("\n").map do |s|
        line = wrap_line s, opts.merge(:inner => inner)
        inner = true
        line
      end.flatten
    end
  end

  ## The per-parser version of Trollop::die (see that for documentation).
  def die(arg, msg = nil, error_code = nil)
    msg, error_code = nil, msg if msg.kind_of?(Fixnum)
    if msg
      $stderr.puts "Error: argument --#{@specs[arg].long} #{msg}."
    else
      $stderr.puts "Error: #{arg}."
    end
    if @educate_on_error
      $stderr.puts
      educate $stderr
    else
      $stderr.puts "Try --help for help."
    end
    exit(error_code || -1)
  end

private

  ## yield successive arg, parameter pairs
  def each_arg(args)
    remains = []
    i = 0

    until i >= args.length
      return remains += args[i..-1] if @stop_words.member? args[i]
      case args[i]
      when /^--$/ # arg terminator
        return remains += args[(i + 1)..-1]
      when /^--(\S+?)=(.*)$/ # long argument with equals
        num_params_taken = yield "--#{$1}", [$2]
        if num_params_taken.nil?
          remains << args[i]
          if @stop_on_unknown
            return remains += args[i + 1..-1]
          end
        end
        i += 1
      when /^--(\S+)$/ # long argument
        params = collect_argument_parameters(args, i + 1)
        num_params_taken = yield args[i], params

        if num_params_taken.nil?
          remains << args[i]
          if @stop_on_unknown
            return remains += args[i + 1..-1]
          end
        else
          i += num_params_taken
        end
        i += 1
      when /^-(\S+)$/ # one or more short arguments
        short_remaining = ""
        shortargs = $1.split(//)
        shortargs.each_with_index do |a, j|
          if j == (shortargs.length - 1)
            params = collect_argument_parameters(args, i + 1)

            num_params_taken = yield "-#{a}", params
            unless num_params_taken
              short_remaining << a
              if @stop_on_unknown
                remains << "-#{short_remaining}"
                return remains += args[i + 1..-1]
              end
            else
              i += num_params_taken
            end
          else
            unless yield "-#{a}", []
              short_remaining << a
              if @stop_on_unknown
                short_remaining += shortargs[j + 1..-1].join
                remains << "-#{short_remaining}"
                return remains += args[i + 1..-1]
              end
            end
          end
        end

        unless short_remaining.empty?
          remains << "-#{short_remaining}"
        end
        i += 1
      else
        if @stop_on_unknown
          return remains += args[i..-1]
        else
          remains << args[i]
          i += 1
        end
      end
    end

    remains
  end

  def collect_argument_parameters(args, start_at)
    params = []
    pos = start_at
    while args[pos] && args[pos] !~ PARAM_RE && !@stop_words.member?(args[pos]) do
      params << args[pos]
      pos += 1
    end
    params
  end

  def resolve_default_short_options!
    @order.each do |type, name|
      opts = @specs[name]
      next if type != :opt || opts.short

      c = opts.long.split(//).find { |d| d !~ INVALID_SHORT_ARG_REGEX && !@short.member?(d) }
      if c # found a character to use
        opts.short = c
        @short[c] = name
      end
    end
  end

  def wrap_line(str, opts = {})
    prefix = opts[:prefix] || 0
    width = opts[:width] || (self.width - 1)
    start = 0
    ret = []
    until start > str.length
      nextt =
        if start + width >= str.length
          str.length
        else
          x = str.rindex(/\s/, start + width)
          x = str.index(/\s/, start) if x && x < start
          x || str.length
        end
      ret << ((ret.empty? && !opts[:inner]) ? "" : " " * prefix) + str[start...nextt]
      start = nextt + 1
    end
    ret
  end

  ## instance_eval but with ability to handle block arguments
  ## thanks to _why: http://redhanded.hobix.com/inspect/aBlockCostume.html
  def cloaker(&b)
    (class << self; self; end).class_eval do
      define_method :cloaker_, &b
      meth = instance_method :cloaker_
      remove_method :cloaker_
      meth
    end
  end
end

## Determines which type of object to create based on arguments passed
## to +Trollop::opt+.  This is trickier in Trollop, than other cmdline
## parsers (e.g. Slop) because we allow the +default:+ to be able to
## set the option's type.

class OptionDispatch

  attr_reader :optinst

  def initialize(name, desc="", opts={}, settings={} &b)

    opttype = Trollop::Parser.registry_getopttype(opts[:type])
    opttype_from_default = get_klass_from_default(opts, opttype)

    raise ArgumentError, ":type specification and default type don't match (default type is #{opttype_from_default.class})" if opttype && opttype_from_default && (opttype.class != opttype_from_default.class)

    @optinst = (opttype || opttype_from_default || Trollop::BooleanOption.new)

    ## fill in :long
    @optinst.long = handle_long_opt opts[:long], name

    ## fill in :short
    @optinst.short = handle_short_opt opts[:short]
    
    ## fill in :multi, :hidden
    @optinst.multi_given = opts[:multi] || false
    @optinst.hidden = opts[:hidden] || false

    ## fill in :default for flags
    defvalue = opts[:default] || @optinst.default 

    ## autobox :default for :multi (multi-occurrence) arguments
    defvalue = [defvalue] if defvalue && @optinst.multi_given && !defvalue.kind_of?(Array)
    @optinst.default = defvalue
    @optinst.name = name
    @optinst.opts = opts
  end

  def get_type_from_disdef(optdef, opttype, disambiguated_default)
    if disambiguated_default.is_a? Array
      return(optdef.first.class.name.downcase + "s") if !optdef.empty?
      if opttype
        raise ArgumentError, "multiple argument type must be plural" unless opttype.multi?
        return nil
      else
        raise ArgumentError, "multiple argument type cannot be deduced from an empty array"
      end
    end
    return disambiguated_default.class.name.downcase
  end
  
  def get_klass_from_default(opts, opttype)
    ## for options with :multi => true, an array default doesn't imply
    ## a multi-valued argument. for that you have to specify a :type
    ## as well. (this is how we disambiguate an ambiguous situation;
    ## see the docs for Parser#opt for details.)

    disambiguated_default = if opts[:multi] && opts[:default].is_a?(Array) && opttype.nil?
                              opts[:default].first
                            else
                              opts[:default]
                            end

    return nil if disambiguated_default.nil?
    type_from_default = get_type_from_disdef(opts[:default], opttype, disambiguated_default) 
    return Trollop::Parser.registry_getopttype(type_from_default)
  end



  def handle_long_opt(lopt, name)
    lopt = lopt ? lopt.to_s : name.to_s.gsub("_", "-")
    lopt = case lopt
           when /^--([^-].*)$/ then $1
           when /^[^-]/        then lopt
           else                     raise ArgumentError, "invalid long option name #{lopt.inspect}"
           end
  end
  
  def handle_short_opt(sopt)
    sopt = sopt.to_s if sopt && sopt != :none
    sopt = case sopt
           when /^-(.)$/          then $1
           when nil, :none, /^.$/ then sopt
           else                   raise ArgumentError, "invalid short option name '#{sopt.inspect}'"
           end

    if sopt
      raise ArgumentError, "a short option name can't be a number or a dash" if sopt =~ ::Trollop::Parser::INVALID_SHORT_ARG_REGEX
    end
    return sopt
  end
  
  def self.create(name, desc="", opts={}, settings={})
    optdispatch = new(name, desc, opts, settings)
    return optdispatch.optinst
  end
end

# ## The option for each flag
# class Option
#   # The set of values that indicate a flag option when passed as the
#   # +:type+ parameter of #opt.
#   FLAG_TYPES = [:flag, :bool, :boolean] #:nodoc:
# 
#   # The set of values that indicate a single-parameter (normal) option when
#   # passed as the +:type+ parameter of #opt.
#   #
#   # A value of +io+ corresponds to a readable IO resource, including
#   # a filename, URI, or the strings 'stdin' or '-'.
#   SINGLE_ARG_TYPES = [:int, :integer, :string, :double, :float, :io, :date] #:nodoc:
# 
#   # The set of values that indicate a multiple-parameter option (i.e., that
#   # takes multiple space-separated values on the commandline) when passed as
#   # the +:type+ parameter of #opt.
#   MULTI_ARG_TYPES = [:ints, :integers, :strings, :doubles, :floats, :ios, :dates] #:nodoc:
# 
#   # The complete set of legal values for the +:type+ parameter of #opt.
#   TYPES = FLAG_TYPES + SINGLE_ARG_TYPES + MULTI_ARG_TYPES #:nodoc:
# 
#   attr_accessor :name, :opts
# 
#   def initialize(name, desc="", opts={}, &b)
#     ## fill in :type
#     opts[:type] = # normalize
#       case opts[:type]
#       when :boolean, :bool then :flag
#       when :integer        then :int
#       when :integers       then :ints
#       when :double         then :float
#       when :doubles        then :floats
#       when Class
#         case opts[:type].name
#         when 'TrueClass',
#              'FalseClass'  then :flag
#         when 'String'      then :string
#         when 'Integer'     then :int
#         when 'Float'       then :float
#         when 'IO'          then :io
#         when 'Date'        then :date
#         else
#           raise ArgumentError, "unsupported argument type '#{opts[:type].class.name}'"
#         end
#       when nil             then nil
#       else
#         raise ArgumentError, "unsupported argument type '#{opts[:type]}'" unless TYPES.include?(opts[:type])
#         opts[:type]
#       end
# 
#     ## for options with :multi => true, an array default doesn't imply
#     ## a multi-valued argument. for that you have to specify a :type
#     ## as well. (this is how we disambiguate an ambiguous situation;
#     ## see the docs for Parser#opt for details.)
#     disambiguated_default = if opts[:multi] && opts[:default].kind_of?(Array) && !opts[:type]
#       opts[:default].first
#     else
#       opts[:default]
#     end
# 
#     type_from_default =
#       case disambiguated_default
#       when Integer     then :int
#       when Numeric     then :float
#       when TrueClass,
#            FalseClass  then :flag
#       when String      then :string
#       when IO          then :io
#       when Date        then :date
#       when Array
#         if opts[:default].empty?
#           if opts[:type]
#             raise ArgumentError, "multiple argument type must be plural" unless MULTI_ARG_TYPES.include?(opts[:type])
#             nil
#           else
#             raise ArgumentError, "multiple argument type cannot be deduced from an empty array for '#{opts[:default][0].class.name}'"
#           end
#         else
#           case opts[:default][0]    # the first element determines the types
#           when Integer then :ints
#           when Numeric then :floats
#           when String  then :strings
#           when IO      then :ios
#           when Date    then :dates
#           else
#             raise ArgumentError, "unsupported multiple argument type '#{opts[:default][0].class.name}'"
#           end
#         end
#       when nil         then nil
#       else
#         raise ArgumentError, "unsupported argument type '#{opts[:default].class.name}'"
#       end
# 
#     raise ArgumentError, ":type specification and default type don't match (default type is #{type_from_default})" if opts[:type] && type_from_default && opts[:type] != type_from_default
# 
#     opts[:type] = opts[:type] || type_from_default || :flag
# 
#     ## fill in :long
#     opts[:long] = opts[:long] ? opts[:long].to_s : name.to_s.gsub("_", "-")
#     opts[:long] = case opts[:long]
#       when /^--([^-].*)$/ then $1
#       when /^[^-]/        then opts[:long]
#       else                     raise ArgumentError, "invalid long option name #{opts[:long].inspect}"
#     end
# 
#     ## fill in :short
#     opts[:short] = opts[:short].to_s if opts[:short] && opts[:short] != :none
#     opts[:short] = case opts[:short]
#       when /^-(.)$/          then $1
#       when nil, :none, /^.$/ then opts[:short]
#       else                   raise ArgumentError, "invalid short option name '#{opts[:short].inspect}'"
#     end
# 
#     if opts[:short]
#       raise ArgumentError, "a short option name can't be a number or a dash" if opts[:short] =~ ::Trollop::Parser::INVALID_SHORT_ARG_REGEX
#     end
# 
#     ## fill in :default for flags
#     opts[:default] = false if opts[:type] == :flag && opts[:default].nil?
# 
#     ## autobox :default for :multi (multi-occurrence) arguments
#     opts[:default] = [opts[:default]] if opts[:default] && opts[:multi] && !opts[:default].kind_of?(Array)
# 
#     ## fill in :multi
#     opts[:multi] ||= false
# 
#     ## fill in :hidden
#     opts[:hidden] ||= false
#     
#     self.name = name
#     self.opts = opts
#   end
# 
#   def key?(name)
#     opts.key?(name)
#   end
# 
#   def type ; opts[:type] ; end
#   def flag? ; type == :flag ; end
#   def single_arg?
#     SINGLE_ARG_TYPES.include?(type)
#   end
# 
# 
#   def multi ; opts[:multi] ; end
#   alias multi? multi
# 
#   def hidden ; opts[:hidden] ; end
#   
#   def multi_arg?
#     MULTI_ARG_TYPES.include?(type)
#   end
# 
#   def default ; opts[:default] ; end
#   #? def multi_default ; opts.default || opts.multi && [] ; end
#   def array_default? ; opts[:default].kind_of?(Array) ; end
# 
#   def short ; opts[:short] ; end
#   def short? ; short && short != :none ; end
#   # not thrilled about this
#   def short=(val) ; opts[:short] = val ; end
#   def long ; opts[:long] ; end
#   def callback ; opts[:callback] ; end
#   def desc ; opts[:desc] ; end
# 
#   def required? ; opts[:required] ; end
# 
#   # works for all except flags
#   def parse(params, arg) #:nodocs:
#     case type
#     #when :flag
#     #  (sym.to_s =~ /^no_/ ? negative_given : !negative_given)
#     when :int, :ints
#       params.map { |pg| pg.map { |p| parse_integer_parameter p, arg } }
#     when :float, :floats
#       params.map { |pg| pg.map { |p| parse_float_parameter p, arg } }
#     when :string, :strings
#       params.map { |pg| pg.map(&:to_s) }
#     when :io, :ios
#       params.map { |pg| pg.map { |p| parse_io_parameter p, arg } }
#     when :date, :dates
#       params.map { |pg| pg.map { |p| parse_date_parameter p, arg } }
#     end
#   end
# 
#   private
# 
#   def parse_integer_parameter(param, arg) #:nodoc:
#     raise CommandlineError, "option '#{arg}' needs an integer" unless param =~ /^-?[\d_]+$/
#     param.to_i
#   end
# 
#   def parse_float_parameter(param, arg) #:nodoc:
#     raise CommandlineError, "option '#{arg}' needs a floating-point number" unless param =~ FLOAT_RE
#     param.to_f
#   end
# 
#   def parse_io_parameter(param, arg) #:nodoc:
#     if param =~ /^(stdin|-)$/i
#       $stdin
#     else
#       require 'open-uri'
#       begin
#         open param
#       rescue SystemCallError => e
#         raise CommandlineError, "file or url for option '#{arg}' cannot be opened: #{e.message}"
#       end
#     end
#   end
# 
#   def parse_date_parameter(param, arg) #:nodoc:
#     begin
#       require 'chronic'
#       time = Chronic.parse(param)
#     rescue LoadError
#       # chronic is not available
#     end
#     time ? Date.new(time.year, time.month, time.day) : Date.parse(param)
#   rescue ArgumentError
#     raise CommandlineError, "option '#{arg}' needs a date"
#   end
# 
#   def self.create(name, desc="", opts={})
#     new(name, desc, opts)
#   end
# end

## The easy, syntactic-sugary entry method into Trollop. Creates a Parser,
## passes the block to it, then parses +args+ with it, handling any errors or
## requests for help or version information appropriately (and then exiting).
## Modifies +args+ in place. Returns a hash of option values.
##
## The block passed in should contain zero or more calls to +opt+
## (Parser#opt), zero or more calls to +text+ (Parser#text), and
## probably a call to +version+ (Parser#version).
##
## The returned block contains a value for every option specified with
## +opt+.  The value will be the value given on the commandline, or the
## default value if the option was not specified on the commandline. For
## every option specified on the commandline, a key "<option
## name>_given" will also be set in the hash.
##
## Example:
##
##   require 'trollop'
##   opts = Trollop::options do
##     opt :monkey, "Use monkey mode"                    # a flag --monkey, defaulting to false
##     opt :name, "Monkey name", :type => :string        # a string --name <s>, defaulting to nil
##     opt :num_limbs, "Number of limbs", :default => 4  # an integer --num-limbs <i>, defaulting to 4
##   end
##
##   ## if called with no arguments
##   p opts # => {:monkey=>false, :name=>nil, :num_limbs=>4, :help=>false}
##
##   ## if called with --monkey
##   p opts # => {:monkey=>true, :name=>nil, :num_limbs=>4, :help=>false, :monkey_given=>true}
##
## Settings:
##   Trollop::options and Trollop::Parser.new accept +settings+ to control how
##   options are interpreted.  These settings are given as hash arguments, e.g:
##
##   opts = Trollop::options(ARGV, :inexact_match => true, :disable_auto_short_opts => true ) do
##     opt :foobar, 'messed up'
##     opt :forget, 'forget it'
##   end
##
##  +settings+ include:
##  * :inexact_match  : Allow minimum unambigous number of characters to match a long option
##  * :disable_auto_short_opts  : Prevent automatic creation of short options
##  * :suggestions  : Enables suggestions when unknown arguments are given and DidYouMean is installed.  DidYouMean comes standard with Ruby 2.3+
##  Because Trollop::options uses a default argument for +args+, you must pass that argument when using the settings feature.

## See more examples at http://trollop.rubyforge.org.
def options(args = ARGV, *a, &b)
  @last_parser = Parser.new(*a, &b)
  with_standard_exception_handling(@last_parser) { @last_parser.parse args }
end

## If Trollop::options doesn't do quite what you want, you can create a Parser
## object and call Parser#parse on it. That method will throw CommandlineError,
## HelpNeeded and VersionNeeded exceptions when necessary; if you want to
## have these handled for you in the standard manner (e.g. show the help
## and then exit upon an HelpNeeded exception), call your code from within
## a block passed to this method.
##
## Note that this method will call System#exit after handling an exception!
##
## Usage example:
##
##   require 'trollop'
##   p = Trollop::Parser.new do
##     opt :monkey, "Use monkey mode"                     # a flag --monkey, defaulting to false
##     opt :goat, "Use goat mode", :default => true       # a flag --goat, defaulting to true
##   end
##
##   opts = Trollop::with_standard_exception_handling p do
##     o = p.parse ARGV
##     raise Trollop::HelpNeeded if ARGV.empty? # show help screen
##     o
##   end
##
## Requires passing in the parser object.

def with_standard_exception_handling(parser)
  yield
rescue CommandlineError => e
  parser.die(e.message, nil, e.error_code)
rescue HelpNeeded
  parser.educate
  exit
rescue VersionNeeded
  puts parser.version
  exit
end

## Informs the user that their usage of 'arg' was wrong, as detailed by
## 'msg', and dies. Example:
##
##   options do
##     opt :volume, :default => 0.0
##   end
##
##   die :volume, "too loud" if opts[:volume] > 10.0
##   die :volume, "too soft" if opts[:volume] < 0.1
##
## In the one-argument case, simply print that message, a notice
## about -h, and die. Example:
##
##   options do
##     opt :whatever # ...
##   end
##
##   Trollop::die "need at least one filename" if ARGV.empty?
##
## An exit code can be provide if needed
##
##   Trollop::die "need at least one filename", -2 if ARGV.empty?
def die(arg, msg = nil, error_code = nil)
  if @last_parser
    @last_parser.die arg, msg, error_code
  else
    raise ArgumentError, "Trollop::die can only be called after Trollop::options"
  end
end

## Displays the help message and dies. Example:
##
##   options do
##     opt :volume, :default => 0.0
##     banner <<-EOS
##   Usage:
##          #$0 [options] <name>
##   where [options] are:
##   EOS
##   end
##
##   Trollop::educate if ARGV.empty?
def educate
  if @last_parser
    @last_parser.educate
    exit
  else
    raise ArgumentError, "Trollop::educate can only be called after Trollop::options"
  end
end

module_function :options, :die, :educate, :with_standard_exception_handling
end # module
