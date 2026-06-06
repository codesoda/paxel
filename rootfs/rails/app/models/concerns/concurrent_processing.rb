# Provides bounded thread pool execution for parallel processing.
# Extracted from AnthropicClient so non-LLM services (e.g. ClientPipeline)
# can use concurrent processing without pulling in the Anthropic client.
#
# Usage:
#   include ConcurrentProcessing
#
#   with_thread_pool(20) do |executor|
#     items.map { |item|
#       Concurrent::Promises.future_on(executor) { process(item) }
#     }.each { |f| f.wait!(120) }
#   end
module ConcurrentProcessing
  extend ActiveSupport::Concern

  private

  def with_thread_pool(max_threads)
    pool = Concurrent::FixedThreadPool.new(max_threads)
    executor = (defined?(Rails) && Rails.env.test?) ? Concurrent::ImmediateExecutor.new : pool
    yield executor
  ensure
    if pool
      pool.shutdown
      pool.wait_for_termination(10) || pool.kill
    end
  end
end
