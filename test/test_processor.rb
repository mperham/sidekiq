require 'helper'
require 'sidekiq/processor'

class TestProcessor < MiniTest::Unit::TestCase
  describe 'with mock setup' do
    before do
      $invokes = 0
      $errors = []
      @boss = MiniTest::Mock.new
      Celluloid.logger = nil
    end

    class MockWorker
      include Sidekiq::Worker
      def perform(args)
        raise "kerboom!" if args == 'boom'
        $invokes += 1
      end
    end

    it 'processes as expected' do
      msg = { 'class' => MockWorker.to_s, 'args' => ['myarg'] }
      processor = ::Sidekiq::Processor.new(@boss)
      @boss.expect(:processor_done!, nil, [processor])
      processor.process(msg, 'default')
      @boss.verify
      assert_equal 1, $invokes
      assert_equal 0, $errors.size
    end

    it 'handles exceptions' do
      msg = { 'class' => MockWorker.to_s, 'args' => ['boom'] }
      processor = ::Sidekiq::Processor.new(@boss)
      assert_raises RuntimeError do
        processor.process(msg, 'default')
      end
      @boss.verify
      assert_equal 0, $invokes
      assert_equal 1, $errors.size
      assert_equal msg, $errors[0][:parameters]
    end

  end
end

class FakeAirbrake
  def self.notify(ex, hash)
    $errors << hash
  end
end
Airbrake = FakeAirbrake

