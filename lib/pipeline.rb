require 'rubygems'
require 'yaml'
require 'set'
require 'tempfile'

module Pipeline

  #This exit code is used when warnings are found and the --exit-on-warn
  #option is set
  Warnings_Found_Exit_Code = 3

  @debug = false
  @quiet = false
  @loaded_dependencies = []

  #Run Pipeline.
  #
  #Options:
  #
  #  * :config_file - configuration file
  #  * :exit_on_warn - return false if warnings found, true otherwise. Not recommended for library use (default: false)
  #  * :output_files - files for output
  #  * :output_formats - formats for output (:to_s, :to_tabs, :to_csv, :to_html)
  #  * :parallel_checks - run checks in parallel (default: true)
  #  * :print_report - if no output file specified, print to stdout (default: false)
  #  * :quiet - suppress most messages (default: true)
  def self.run options
    options = set_options options

    @quiet = !!options[:quiet]
    @debug = !!options[:debug]

    if @quiet
      options[:report_progress] = false
    end

    scan options
  end

  #Sets up options for run, checks given application path
  def self.set_options options
    if options.is_a? String
      options = { :target => options }
    end

    if options[:quiet] == :command_line
      command_line = true
      options.delete :quiet
    end

    options = default_options.merge(load_options(options[:config_file], options[:quiet])).merge(options)

    if options[:quiet].nil? and not command_line
      options[:quiet] = true
    end

    options[:output_format] = get_output_format options

    if options[:appname].nil?
      path = options[:target]
      options[:appname] = File.split(path).last
    end



    options
  end

  CONFIG_FILES = [
    File.expand_path("./config/pipeline.yml"),
    File.expand_path("~/.pipeline/config.yml"),
    File.expand_path("/etc/pipeline/config.yml")
  ]

  #Load options from YAML file
  def self.load_options custom_location, quiet
    #Load configuration file
    if config = config_file(custom_location)
      options = YAML.load_file config

      if options
        options.each { |k, v| options[k] = Set.new v if v.is_a? Array }

        # notify if options[:quiet] and quiet is nil||false
        notify "[Notice] Using configuration in #{config}" unless (options[:quiet] || quiet)
        options
      else
        notify "[Notice] Empty configuration file: #{config}" unless quiet
        {}
      end
    else
      {}
    end
  end

  def self.config_file custom_location = nil
    supported_locations = [File.expand_path(custom_location || "")] + CONFIG_FILES
    supported_locations.detect {|f| File.file?(f) }
  end

  #Default set of options
  def self.default_options
    {
      :parallel_tasks => true,
      :skip_tasks => Set.new(),
      :output_format => :text,
      :working_dir => "~/line/tmp/",
      :labels => Set.new() << "filesystem" << "code"     # Defaults to run.
    }
  end

  #Determine output formats based on options[:output_formats]
  #or options[:output_files]
  def self.get_output_format options
    if options[:output_file]
      get_format_from_output_file options[:output_file]
    elsif options[:output_format]
      get_format_from_output_format options[:output_format]
    else
      begin
        require 'terminal-table'
        return [:to_s]
      rescue LoadError
        return [:to_json]
      end
    end
  end

  def self.get_format_from_output_format output_format
    case output_format
    when :html, :to_html
      [:to_html]
    when :csv, :to_csv
      [:to_csv]
    when :pdf, :to_pdf
      [:to_pdf]
    when :tabs, :to_tabs
      [:to_tabs]
    when :json, :to_json
      [:to_json]
    when :jira, :to_jira
      [:to_jira]
    when :markdown, :to_markdown
      [:to_markdown]
    else
      [:to_s]
    end
  end
  private_class_method :get_format_from_output_format

  def self.get_format_from_output_file output_file
      case output_file
      when /\.html$/i
        :to_html
      when /\.csv$/i
        :to_csv
      when /\.pdf$/i
        :to_pdf
      when /\.tabs$/i
        :to_tabs
      when /\.json$/i
        :to_json
      when /\.md$/i
        :to_markdown
      else
        :to_s
      end
  end
  private_class_method :get_format_from_output_file

  #Output list of tasks (for `-k` option)
  def self.list_checks options
    require 'pipeline/scanner'

    add_external_tasks options

    if options[:list_optional_tasks]
      $stderr.puts "Optional Tasks:"
      tasks = Tasks.optional_tasks
    else
      $stderr.puts "Available tasks:"
      tasks = Tasks.tasks
    end

    format_length = 30

    $stderr.puts "-" * format_length
    tasks.each do |task|
      $stderr.printf("%-#{format_length}s\n", task.name)
    end
  end

  #Output configuration to YAML
  def self.dump_config options
    if options[:create_config].is_a? String
      file = options[:create_config]
    else
      file = nil
    end

    options.delete :create_config

    options.each do |k,v|
      if v.is_a? Set
        options[k] = v.to_a
      end
    end

    if file
      File.open file, "w" do |f|
        YAML.dump options, f
      end
      puts "Output configuration to #{file}"
    else
      puts YAML.dump(options)
    end
    exit
  end

  #Run a scan. Generally called from Pipeline.run instead of directly.
  def self.scan options
    #Load scanner
    notify "Loading scanner..."

    begin
      require 'pipeline/scanner'
      require 'pipeline/tracker'
      require 'pipeline/mounters'
      require 'pipeline/filters'
      require 'pipeline/reporters'

    rescue LoadError => e
      $stderr.puts e.message
      raise NoPipelineError, "Cannot find lib/ directory or load the key pipeline."
    end

#    debug "API: #{options[:jira_api_url.to_s]}"
#    debug "Project: #{options[:jira_project.to_s]}"
#    debug "Cookie: #{options[:jira_cookie.to_s]}"

    add_external_tasks options

    tracker = Tracker.new options
    debug "Mounting ... #{options[:target]}"
    # Make the target accessible.
    target = Pipeline::Mounters.mount tracker

    #Start scanning
    scanner = Scanner.new
    notify "Processing target...#{options[:target]}"
    scanner.process target, tracker

    # Filter the results (Don't report anything that has been reported before)
    Pipeline::Filters.filter tracker

    # Generate Report
    notify "Generating report...#{options[:output_format]}"
    Pipeline::Reporters.run_report tracker

    tracker
  end

  def self.error message
    $stderr.puts message
  end

  def self.warn message
    $stderr.puts message unless @quiet
  end

  def self.notify message
    $stderr.puts message #unless @debug
  end

  def self.debug message
    $stderr.puts message if @debug
  end

  def self.load_pipeline_dependency name
    return if @loaded_dependencies.include? name

    begin
      require name
    rescue LoadError => e
      $stderr.puts e.message
      $stderr.puts "Please install the appropriate dependency."
      exit! -1
    end
  end

  def self.add_external_tasks options
    options[:additional_tasks_path].each do |path|
      Pipeline::Tasks.initialize_tasks path
    end if options[:additional_tasks_path]
  end

  class DependencyError < RuntimeError; end
  class NoPipelineError < RuntimeError; end
  class NoTargetError < RuntimeError; end
  class JiraConfigError < RuntimeError; end
end
