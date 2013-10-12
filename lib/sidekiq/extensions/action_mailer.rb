require 'sidekiq/extensions/marshal_proxy'

module Sidekiq
  module Extensions
    ##
    # Adds 'delay', 'delay_for' and `delay_until` methods to ActionMailer to offload arbitrary email
    # delivery to Sidekiq.  Example:
    #
    #    UserMailer.delay.send_welcome_email(new_user)
    #    UserMailer.delay_for(5.days).send_welcome_email(new_user)
    #    UserMailer.delay_until(5.days.from_now).send_welcome_email(new_user)
    class DelayedMailer
      include Sidekiq::Worker

      def perform(bytes)
        (target, method_name, args) = self.class.load(bytes)
        msg = target.send(method_name, *args)
        # The email method can return nil, which causes ActionMailer to return
        # an undeliverable empty message.
        msg.deliver if msg && (msg.to || msg.cc || msg.bcc) && msg.from
      end

      def self.load(bytes)
        Marshal.load(bytes.pack('c*'))
      end
    end

    module ActionMailer
      def delay(options={})
        MarshalProxy.new(DelayedMailer, self, options)
      end
      def delay_for(interval, options={})
        MarshalProxy.new(DelayedMailer, self, options.merge('at' => Time.now.to_f + interval.to_f))
      end
      def delay_until(timestamp, options={})
        MarshalProxy.new(DelayedMailer, self, options.merge('at' => timestamp.to_f))
      end
    end

  end
end
