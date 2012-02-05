module Sidekiq
  # Middleware is code configured to run before/after
  # a message is processed.  It is patterned after Rack
  # middleware.  The default middleware chain:
  #
  # Sidekiq::Middleware::Chain.register do
  #   use Sidekiq::Airbrake
  #   use Sidekiq::ActiveRecord
  # end
  #
  # This is an example of a minimal middleware:
  #
  # class MyHook
  #   def initialize(options=nil)
  #   end
  #   def call(worker, msg)
  #     puts "Before work"
  #     yield
  #     puts "After work"
  #   end
  # end
  #
  module Middleware
    class Chain
      def self.register(&block)
        instance_exec(&block)
      end

      def self.default
        @default ||= [Entry.new(Airbrake), Entry.new(ActiveRecord)]
      end

      def self.use(klass, *args)
        chain << Entry.new(klass, args)
      end

      def self.chain
        @chain ||= default
      end

      def self.retrieve
        Thread.current[:sidekiq_chain] ||= chain.map { |entry| entry.make_new }
      end
    end

    class Entry
      attr_reader :klass
      def initialize(klass, args = [])
        @klass = klass
        @args  = args
      end

      def make_new
        @klass.new(*@args)
      end
    end
  end

  class Airbrake
    def initialize(options=nil)
    end

    def call(worker, msg)
      yield
    rescue => ex
      send_to_airbrake(msg, ex) if defined?(::Airbrake)
      raise
    end

    private

    def send_to_airbrake(msg, ex)
      ::Airbrake.notify(:error_class   => ex.class.name,
                        :error_message => "#{ex.class.name}: #{ex.message}",
                        :parameters    => msg)
    end
  end

  class ActiveRecord
    def initialize(options=nil)
    end

    def call(*)
      yield
    ensure
      ActiveRecord::Base.clear_active_connections! if defined?(::ActiveRecord)
    end
  end
end
