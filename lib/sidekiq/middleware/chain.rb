module Sidekiq
  # Middleware is code configured to run before/after
  # a message is processed.  It is patterned after Rack
  # middleware. Middleware exists for the client side
  # (pushing jobs onto the queue) as well as the server
  # side (when jobs are actually processed).
  #
  # To add middleware for the client:
  #
  # Sidekiq.configure_client do |config|
  #   config.client_middleware do |chain|
  #     chain.add MyClientHook
  #   end
  # end
  #
  # To modify middleware for the server, just call
  # with another block:
  #
  # Sidekiq.configure_server do |config|
  #   config.server_middleware do |chain|
  #     chain.add MyServerHook
  #     chain.remove ActiveRecord
  #   end
  # end
  #
  # To insert immediately preceding another entry:
  #
  # Sidekiq.configure_client do |config|
  #   config.client_middleware do |chain|
  #     chain.insert_before ActiveRecord, MyClientHook
  #   end
  # end
  #
  # To insert immediately after another entry:
  #
  # Sidekiq.configure_client do |config|
  #   config.client_middleware do |chain|
  #     chain.insert_after ActiveRecord, MyClientHook
  #   end
  # end
  #
  # This is an example of a minimal server middleware:
  #
  # class MyServerHook
  #   def call(worker_instance, msg, queue)
  #     puts "Before work"
  #     yield
  #     puts "After work"
  #   end
  # end
  #
  # This is an example of a minimal client middleware:
  #
  # class MyClientHook
  #   def call(worker_class, msg, queue)
  #     puts "Before push"
  #     yield
  #     puts "After push"
  #   end
  # end
  #
  module Middleware
    class Chain
      include Enumerable
      attr_reader :entries

      def each(&block)
        entries.each(&block)
      end

      def initialize
        @entries = []
        yield self if block_given?
      end

      def remove(klass)
        entries.delete_if { |entry| entry.klass == klass }
      end

      def add(klass, *args)
        entries << Entry.new(klass, *args) unless exists?(klass)
      end

      def insert_before(oldklass, newklass, *args)
        i = entries.index { |entry| entry.klass == newklass }
        new_entry = i.nil? ? Entry.new(newklass, *args) : entries.delete_at(i)
        i = entries.find_index { |entry| entry.klass == oldklass } || 0
        entries.insert(i, new_entry)
      end

      def insert_after(oldklass, newklass, *args)
        i = entries.index { |entry| entry.klass == newklass }
        new_entry = i.nil? ? Entry.new(newklass, *args) : entries.delete_at(i)
        i = entries.find_index { |entry| entry.klass == oldklass } || entries.count - 1
        entries.insert(i+1, new_entry)
      end

      def exists?(klass)
        entries.any? { |entry| entry.klass == klass }
      end

      def retrieve
        entries.map(&:make_new)
      end

      def clear
        entries.clear
      end

      def invoke(*args, &final_action)
        chain = retrieve.dup
        value = nil
        traverse_chain = lambda do
          if chain.empty?
            value = final_action.call(*args)
          else
            chain.shift.call(*args, &traverse_chain)
          end
        end
        traverse_chain.call
        value
      end

      def invoke_bulk(*args_array, &final_action)
        succeeded = []
        value = nil

        # Go down each chain before the yield
        next_chain = lambda do |args, chain|
          myargs = args

          if not myargs.nil?
            success = false

            if chain.empty?
              success = true
              succeeded << args

              # Call the start of the next chain
              next_chain.call(args_array.shift, retrieve)
            else
              chain.shift.call(*args) do
                next_chain.call(args, chain)
              end
            end

            # Even if something in the chain failed to yield, just go to the next chain
            if chain.empty? and not success
              next_chain.call(args_array.shift, retrieve)
            end
          else
            # Run the final action on all items that succeeded
            value = final_action.call(*succeeded)
          end

          # On return, we will fall to all the after yield actions
        end

        next_chain.call(args_array.shift, retrieve)
        value
      end
    end

    class Entry
      attr_reader :klass
      def initialize(klass, *args)
        @klass = klass
        @args  = args
      end

      def make_new
        @klass.new(*@args)
      end
    end
  end
end
