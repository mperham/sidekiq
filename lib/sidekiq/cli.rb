trap 'INT' do
  if Sidekiq.options[:profile]
    result = RubyProf.stop
    printer = RubyProf::GraphHtmlPrinter.new(result)
    File.open("profile.html", 'w') do |f|
      printer.print(f, :min_percent => 1)
    end
  end
  # Handle Ctrl-C in JRuby like MRI
  # http://jira.codehaus.org/browse/JRUBY-4637
  Sidekiq::CLI.instance.interrupt
end

trap 'TERM' do
  # Heroku sends TERM and then waits 10 seconds for process to exit.
  Sidekiq::CLI.instance.interrupt
end

trap 'USR1' do
  Sidekiq.logger.info "Received USR1, no longer accepting new work"
  mgr = Sidekiq::CLI.instance.manager
  mgr.async.stop if mgr
end

trap 'USR2' do
  if Sidekiq.options[:logfile]
    Sidekiq.logger.info "Received USR2, reopening log file"
    Sidekiq::Logging.initialize_logger(Sidekiq.options[:logfile])
  end
end

trap 'TTIN' do
  Thread.list.each do |thread|
    Sidekiq.logger.info "Thread TID-#{thread.object_id.to_s(36)} #{thread['label']}"
    if thread.backtrace
      Sidekiq.logger.info thread.backtrace.join("\n")
    else
      Sidekiq.logger.info "<no backtrace available>"
    end
  end
end

$stdout.sync = true

require 'yaml'
require 'singleton'
require 'optparse'
require 'erb'

require 'sidekiq'
require 'sidekiq/util'

module Sidekiq
  class CLI
    include Util
    include Singleton

    # Used for CLI testing
    attr_accessor :code
    attr_accessor :manager
    attr_accessor :environment

    def initialize
      @code = nil
      @interrupt_mutex = Mutex.new
      @interrupted = false
    end

    def parse(args=ARGV)
      @code = nil

      setup_options(args)
      initialize_logger
      validate!
      daemonize
      write_pid
      load_celluloid
      boot_system
    end

    def run
      logger.info "Booting Sidekiq #{Sidekiq::VERSION} with Redis at #{redis {|x| x.client.id}}"
      logger.info "Running in #{RUBY_DESCRIPTION}"
      logger.info Sidekiq::LICENSE

      Sidekiq::Stats::History.cleanup

      if !options[:daemon]
        logger.info 'Starting processing, hit Ctrl-C to stop'
      end

      @manager = Sidekiq::Manager.new(options)
      poller = Sidekiq::Scheduled::Poller.new
      begin
        if options[:profile]
          require 'ruby-prof'
          RubyProf.start
        end
        @manager.async.start
        poller.async.poll(true)
        sleep
      rescue Interrupt
        logger.info 'Shutting down'
        poller.async.terminate if poller.alive?
        @manager.async.stop(:shutdown => true, :timeout => options[:timeout])
        @manager.wait(:shutdown)
        # Explicitly exit so busy Processor threads can't block
        # process shutdown.
        exit(0)
      end
    end

    def interrupt
      @interrupt_mutex.synchronize do
        unless @interrupted
          @interrupted = true
          Thread.main.raise Interrupt
        end
      end
    end

    private

    def load_celluloid
      # Celluloid can't be loaded until after we've daemonized
      # because it spins up threads and creates locks which get
      # into a very bad state if forked.
      require 'celluloid'
      Celluloid.logger = (options[:verbose] ? Sidekiq.logger : nil)

      require 'sidekiq/manager'
      require 'sidekiq/scheduled'
    end

    def daemonize
      return unless options[:daemon]

      raise ArgumentError, "You really should set a logfile if you're going to daemonize" unless options[:logfile]
      files_to_reopen = []
      ObjectSpace.each_object(File) do |file|
        files_to_reopen << file unless file.closed?
      end

      Process.daemon(true, true)

      files_to_reopen.each do |file|
        begin
          file.reopen file.path, "a+"
          file.sync = true
        rescue ::Exception
        end
      end

      [$stdout, $stderr].each do |io|
        File.open(options[:logfile], 'ab') do |f|
          io.reopen(f)
        end
        io.sync = true
      end
      $stdin.reopen('/dev/null')

      initialize_logger
    end

    def set_environment(cli_env)
      @environment = cli_env || ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
    end

    def die(code)
      exit(code)
    end

    def setup_options(args)
      cli = parse_options(args)
      set_environment cli[:environment]

      cfile = cli[:config_file]

      config = (cfile ? parse_config(cfile) : {})
      options.merge!(config.merge(cli))
    end

    def options
      Sidekiq.options
    end

    def boot_system
      ENV['RACK_ENV'] = ENV['RAILS_ENV'] = environment

      raise ArgumentError, "#{options[:require]} does not exist" unless File.exist?(options[:require])

      if File.directory?(options[:require])
        require 'rails'
        require 'sidekiq/rails'
        require File.expand_path("#{options[:require]}/config/environment.rb")
        ::Rails.application.eager_load!
        options[:tag] ||= default_tag
      else
        require options[:require]
      end
    end

    def default_tag
      dir = ::Rails.root
      name = File.basename(dir)
      if name.to_i != 0 && prevdir = File.dirname(dir) # Capistrano release directory?
        if File.basename(prevdir) == 'releases'
          return File.basename(File.dirname(prevdir))
        end
      end
      name
    end

    def validate!
      options[:queues] << 'default' if options[:queues].empty?

      if !File.exist?(options[:require]) ||
         (File.directory?(options[:require]) && !File.exist?("#{options[:require]}/config/application.rb"))
        logger.info "=================================================================="
        logger.info "  Please point sidekiq to a Rails 3 application or a Ruby file    "
        logger.info "  to load your worker classes with -r [DIR|FILE]."
        logger.info "=================================================================="
        logger.info @parser
        die(1)
      end
    end

    def parse_options(argv)
      opts = {}

      @parser = OptionParser.new do |o|
        o.on '-c', '--concurrency INT', "processor threads to use" do |arg|
          opts[:concurrency] = Integer(arg)
        end

        o.on '-d', '--daemon', "Daemonize process" do |arg|
          opts[:daemon] = arg
        end

        o.on '-e', '--environment ENV', "Application environment" do |arg|
          opts[:environment] = arg
        end

        o.on '-g', '--tag TAG', "Process tag for procline" do |arg|
          opts[:tag] = arg
        end

        o.on '-i', '--index INT', "unique process index on this machine" do |arg|
          opts[:index] = Integer(arg)
        end

        o.on '-p', '--profile', "Profile all code run by Sidekiq" do |arg|
          opts[:profile] = arg
        end

        o.on "-q", "--queue QUEUE[,WEIGHT]...", "Queues to process with optional weights" do |arg|
          queues_and_weights = arg.scan(/([\w\.-]+),?(\d*)/)
          parse_queues opts, queues_and_weights
        end

        o.on '-r', '--require [PATH|DIR]', "Location of Rails application with workers or file to require" do |arg|
          opts[:require] = arg
        end

        o.on '-t', '--timeout NUM', "Shutdown timeout" do |arg|
          opts[:timeout] = Integer(arg)
        end

        o.on "-v", "--verbose", "Print more verbose output" do |arg|
          opts[:verbose] = arg
        end

        o.on '-C', '--config PATH', "path to YAML config file" do |arg|
          opts[:config_file] = arg
        end

        o.on '-L', '--logfile PATH', "path to writable logfile" do |arg|
          opts[:logfile] = arg
        end

        o.on '-P', '--pidfile PATH', "path to pidfile" do |arg|
          opts[:pidfile] = arg
        end

        o.on '-V', '--version', "Print version and exit" do |arg|
          puts "Sidekiq #{Sidekiq::VERSION}"
          die(0)
        end
      end

      @parser.banner = "sidekiq [options]"
      @parser.on_tail "-h", "--help", "Show help" do
        logger.info @parser
        die 1
      end
      @parser.parse!(argv)
      opts
    end

    def initialize_logger
      Sidekiq::Logging.initialize_logger(options[:logfile]) if options[:logfile]

      Sidekiq.logger.level = Logger::DEBUG if options[:verbose]
    end

    def write_pid
      if path = options[:pidfile]
        File.open(path, 'w') do |f|
          f.puts Process.pid
        end
      end
    end

    def parse_config(cfile)
      opts = {}
      if File.exist?(cfile)
        opts = YAML.load(ERB.new(IO.read(cfile)).result)
        opts = opts.merge(opts.delete(environment) || {})
        parse_queues opts, opts.delete(:queues) || []
      else
        raise ArgumentError, "can't find config file #{cfile}"
      end
      opts
    end

    def parse_queues(opts, queues_and_weights)
      queues_and_weights.each {|queue_and_weight| parse_queue(opts, *queue_and_weight)}
      opts[:strict] = queues_and_weights.all? {|_, weight| weight.to_s.empty? }
    end

    def parse_queue(opts, q, weight=nil)
      [weight.to_i, 1].max.times do
       (opts[:queues] ||= []) << q
      end
    end
  end
end
