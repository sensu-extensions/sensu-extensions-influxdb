require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'em-http-request'
require 'eventmachine'

module Sensu
  module Extension
    class InfluxRelay
      def init(config)
        @influx_conf = config
        @buffer = {}
        @flush_timer = EventMachine::PeriodicTimer.new(@influx_conf['buffer_max_age'].to_i) do
          unless buffer_size.zero?
            flush_buffer
          end
        end
      end

      def flush_buffer
        logger.info('Flushing Buffer')
        @buffer.each do |db, tps|
          tps.each do |tp, rps|
            rps.each do |rp, points|
              influxdb = EventMachine::HttpRequest.new("#{@influx_conf['base_url']}/write")
              post_data = {}
              query = {
                'db' => db,
                'precision' => tp,
                'u' => @influx_conf['username'],
                'p' => @influx_conf['password']
              }
              query['rp'] = rp unless rp == :default
              post_data[:query] = query
              post_data[:body] = points.join(" \n")
              if @influx_conf['use_basic_auth']
                post_data[:head] = { 'authorization' => [@influx_conf['basic_user'], @influx_conf['basic_pass']] }
              end
              result = influxdb.post(post_data)
              next if @influx_conf.key?(db) && @influx_conf['debug_relay'] == false # this is to avoid the performance impact of checking the response everytime
              result.callback do
                if result.response =~ /.*error.*/
                  logger.error("InfluxDB response: #{result.response}")
                  if result.response =~ /.*database not found.*/
                    post_data = {}
                    post_data[:body] = ''
                    post_data[:query] = {
                      'db' => db,
                      'precision' => p,
                      'u' => @influx_conf['username'],
                      'p' => @influx_conf['password'],
                      'q' => "create database #{db}"
                    }
                    if @influx_conf['use_basic_auth']
                      post_data[:head] = { 'authorization' => [@influx_conf['basic_user'], @influx_conf['basic_pass']] }
                    end
                    EventMachine::HttpRequest.new("#{@influx_conf['base_url']}/query").post(post_data)
                    @influx_conf[db] = true
                  end
                else
                  logger.debug("Written: #{post_data[:body]}")
                  @influx_conf[db] = true
                end
              end
            end
          end
          @buffer[db] = {}
        end
      end

      def buffer_size
        @buffer.map { |_db, tps| tps.map { |_tp, rps| rps.map { |_rp, points| points.length }.inject(:+) }.inject(:+) }.inject(:+) || 0
      end

      def push(database, time_precision, retention_policy, data)
        @buffer[database] ||= {}
        @buffer[database][time_precision] ||= {}
        @buffer[database][time_precision][retention_policy] ||= []

        @buffer[database][time_precision][retention_policy].push(data)
        flush_buffer if buffer_size >= @influx_conf['buffer_max_size']
      end

      def logger
        Sensu::Logger.get
      end
    end
  end
end
