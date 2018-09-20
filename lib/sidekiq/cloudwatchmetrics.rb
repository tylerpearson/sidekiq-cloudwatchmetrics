# frozen_string_literal: true

require "sidekiq"
require "sidekiq/api"
require "sidekiq/util"

require "aws-sdk"

module Sidekiq::CloudWatchMetrics
  def self.enable!(**kwargs)
    Sidekiq.configure_server do |config|
      publisher = Publisher.new(**kwargs)

      if Sidekiq.options[:lifecycle_events].has_key?(:leader)
        # Only publish metrics on the leader if we have a leader (sidekiq-ent)
        config.on(:leader) do
          publisher.start
        end
      else
        # Otherwise pubishing from every node doesn't hurt, it's just wasteful
        config.on(:startup) do
          publisher.start
        end
      end

      config.on(:quiet) do
        publisher.quiet if publisher.running?
      end

      config.on(:shutdown) do
        publisher.stop if publisher.running?
      end
    end
  end

  class Publisher
    include Sidekiq::Util

    INTERVAL = 60 # seconds

    def initialize(client: Aws::CloudWatch::Client.new, namespace: 'Sidekiq', dimensions: [])
      @client = client
      @namespace = namespace
      @dimensions = dimensions
    end

    def start
      logger.info { "Starting Sidekiq CloudWatch Metrics Publisher" }

      @done = false
      @thread = safe_thread("cloudwatch metrics publisher", &method(:run))
    end

    def running?
      !@thread.nil? && @thread.alive?
    end

    def run
      logger.info { "Started Sidekiq CloudWatch Metrics Publisher" }

      # Publish stats every INTERVAL seconds, sleeping as required between runs
      now = Time.now.to_f
      tick = now
      until @stop
        logger.info { "Publishing Sidekiq CloudWatch Metrics" }
        publish

        now = Time.now.to_f
        tick = [tick + INTERVAL, now].max
        sleep(tick - now) if tick > now
      end

      logger.info { "Stopped Sidekiq CloudWatch Metrics Publisher" }
    end

    def publish
      now = Time.now
      stats = Sidekiq::Stats.new
      processes = Sidekiq::ProcessSet.new.to_enum(:each).to_a
      utilization = calculate_utilization(processes)
      capacity = calculate_capacity(processes)
      queues = stats.queues

      metrics = [
        {
          metric_name: "ProcessedJobs",
          timestamp: now,
          value: stats.processed,
          unit: "Count",
          dimensions: @dimensions
        },
        {
          metric_name: "FailedJobs",
          timestamp: now,
          value: stats.failed,
          unit: "Count",
          dimensions: @dimensions
        },
        {
          metric_name: "EnqueuedJobs",
          timestamp: now,
          value: stats.enqueued,
          unit: "Count",
          dimensions: @dimensions
        },
        {
          metric_name: "ScheduledJobs",
          timestamp: now,
          value: stats.scheduled_size,
          unit: "Count",
          dimensions: @dimensions
        },
        {
          metric_name: "RetryJobs",
          timestamp: now,
          value: stats.retry_size,
          unit: "Count",
          dimensions: @dimensions
        },
        {
          metric_name: "DeadJobs",
          timestamp: now,
          value: stats.dead_size,
          unit: "Count",
          dimensions: @dimensions
        },
        {
          metric_name: "Workers",
          timestamp: now,
          value: stats.workers_size,
          unit: "Count",
          dimensions: @dimensions
        },
        {
          metric_name: "Processes",
          timestamp: now,
          value: stats.processes_size,
          unit: "Count",
          dimensions: @dimensions
        },
        {
          metric_name: "Capacity",
          timestamp: now,
          value: capacity,
          unit: "Count",
          dimensions: @dimensions
        },
        {
          metric_name: "Utilization",
          timestamp: now,
          value: utilization * 100.0,
          unit: "Percent",
          dimensions: @dimensions
        },
        {
          metric_name: "DefaultQueueLatency",
          timestamp: now,
          value: stats.default_queue_latency,
          unit: "Seconds",
          dimensions: @dimensions
        },
      ]

      queues.map do |(queue_name, queue_size)|
        metrics << {
          metric_name: "QueueSize",
          dimensions: [{name: "QueueName", value: queue_name}] + @dimensions,
          timestamp: now,
          value: queue_size,
          unit: "Count",
        }

        queue_latency = Sidekiq::Queue.new(queue_name).latency

        metrics << {
          metric_name: "QueueLatency",
          dimensions: [{name: "QueueName", value: queue_name}] + @dimensions,
          timestamp: now,
          value: queue_latency,
          unit: "Seconds",
        }
      end

      # We can only put 20 metrics at a time
      metrics.each_slice(20) do |some_metrics|
        @client.put_metric_data(
          namespace: @namespace,
          metric_data: some_metrics,
        )
      end
    end

    # Returns the total number of workers across all processes
    private def calculate_capacity(processes)
      processes.map do |process|
        process["concurrency"]
      end.inject(0) {|sum,x| sum + x }
    end

    # Returns busy / concurrency averaged across processes (for scaling)
    private def calculate_utilization(processes)
      processes.map do |process|
        process["busy"] / process["concurrency"].to_f
      end.inject(0) {|sum,x| sum + x } / processes.size.to_f
    end

    def quiet
      logger.info { "Quieting Sidekiq CloudWatch Metrics Publisher" }
      @stop = true
    end

    def stop
      logger.info { "Stopping Sidekiq CloudWatch Metrics Publisher" }
      @stop = true
      @thread.wakeup
      @thread.join
    end
  end
end
