require 'sidekiq'
require 'celluloid'

module Sidekiq
  ##
  # The Fetcher blocks on Redis, waiting for a message to process
  # from the queues.  It gets the message and hands it to the Manager
  # to assign to a ready Processor.
  class Fetcher
    include Celluloid
    include Sidekiq::Util

    TIMEOUT = 1

    def initialize(mgr, options)
      @mgr = mgr
      @strategy = Fetcher.strategy.new(options)
    end

    # Fetching is straightforward: the Manager makes a fetch
    # request for each idle processor when Sidekiq starts and
    # then issues a new fetch request every time a Processor
    # finishes a message.
    #
    # Because we have to shut down cleanly, we can't block
    # forever and we can't loop forever.  Instead we reschedule
    # a new fetch if the current fetch turned up nothing.
    def fetch
      watchdog('Fetcher#fetch died') do
        return if Sidekiq::Fetcher.done?

        begin
          work = @strategy.retrieve_work

          if work
            @mgr.async.assign(work)
          else
            after(0) { fetch }
          end
        rescue => ex
          logger.error("Error fetching message: #{ex}")
          logger.error(ex.backtrace.first)
          sleep(TIMEOUT)
          after(0) { fetch }
        end
      end
    end

    # Ugh.  Say hello to a bloody hack.
    # Can't find a clean way to get the fetcher to just stop processing
    # its mailbox when shutdown starts.
    def self.done!
      @done = true
    end

    def self.done?
      @done
    end

    def self.strategy
      Sidekiq.options[:fetch] || BasicFetch
    end
  end

  class BasicFetch
    def initialize(options)
      @strictly_ordered_queues = !!options[:strict]
      @queues = options[:queues].map { |q| "queue:#{q}" }
      @unique_queues = @queues.uniq
    end

    def retrieve_work
      work = Sidekiq.redis { |conn| conn.brpop(*queues_cmd) }
      UnitOfWork.new(*work) if work
    end

    def self.bulk_requeue(inprogress)
      Sidekiq.logger.debug { "Re-queueing terminated jobs" }
      jobs_to_requeue = {}
      inprogress.each do |unit_of_work|
        jobs_to_requeue[unit_of_work.queue] ||= []
        jobs_to_requeue[unit_of_work.queue] << unit_of_work.message
      end

      Sidekiq.redis do |conn|
        jobs_to_requeue.each do |queue, jobs|
          unless Sidekiq.options[:namespace].nil?
            queue = queue.gsub(/#{Sidekiq.options[:namespace]}:/,'') 
          end          
          conn.rpush(queue, jobs)
        end
      end

      Sidekiq.logger.info("Pushed #{inprogress.size} messages back to Redis")
    end

    UnitOfWork = Struct.new(:queue, :message) do
      def acknowledge
        # nothing to do
      end

      def queue_name
        queue.gsub(/.*queue:/, '')
      end

      def requeue_name
        return queue if Sidekiq.options[:namespace].nil?
        queue.gsub(/#{Sidekiq.options[:namespace]}:/,'') 
      end

      def requeue
        Sidekiq.redis do |conn|  
          conn.rpush(requeue_name, message)
        end
      end
    end

    # Creating the Redis#blpop command takes into account any
    # configured queue weights. By default Redis#blpop returns
    # data from the first queue that has pending elements. We
    # recreate the queue command each time we invoke Redis#blpop
    # to honor weights and avoid queue starvation.
    def queues_cmd
      queues = @strictly_ordered_queues ? @unique_queues.dup : @queues.shuffle.uniq
      queues << Sidekiq::Fetcher::TIMEOUT
    end
  end
end
