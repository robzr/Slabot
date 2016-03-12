# InstantSlackBot::SlackRTM - Slack RTM API class
#
# This class is based on Rémi Delhaye's slack-rtm-api
#   http://github.com/rdlh/slack-rtm-api

require 'json'
require 'net/http'
require 'socket'
require 'websocket/driver'
require 'logger'
require 'thread'
include IO::WaitReadable

module InstantSlackBot

  class SlackRTM
    CLASS = 'InstantSlackBot::SlackRTM'
    VALID_DRIVER_EVENTS = [:open, :close, :message, :error]
    SLACK_RTM_START_URL = 'https://slack.com/api/rtm.start'
    THROTTLE_TIMEOUT = 0.01

    attr_accessor :auto_reconnect, :debug, :ping_threshold
    attr_reader :connection_status

    def initialize(
      auto_start: true,
      auto_reconnect: true,
      debug: false,
      open_wait_timeout: 15,
      ping_threshold: 15,
      select_timeout: THROTTLE_TIMEOUT,
      token: nil,
      url: nil
    )
      @auto_reconnect = auto_reconnect
      @debug = debug
      @open_wait_timeout = open_wait_timeout
      @ping_threshold = ping_threshold
      @select_timeout = select_timeout
      @url = url

      @connection_status = :closed # or [:connecting, :initializing, :open]
      @event_handlers = {}
      @send_queue = Queue.new
      @connection_thread = nil

      if @url || token
        @url ||= get_initial_url(token: token)
        start if auto_start
      else
        raise ArgumentError, "#{CLASS} No url or token provided"
      end
    end

    def bind(event_type: nil, event_handler: nil)
      unless VALID_DRIVER_EVENTS.include? event_type
        raise ArgumentError, "#{CLASS} Invalid event (#{event_type}), valid " \
          "events are: #{VALID_DRIVER_EVENTS}"
      end
      @event_handlers[event_type] = event_handler
    end

    def close
      return if @connection_status == :closed
      @connection_status = :closed
      @connection_thread.kill if @connection_thread
      @connection_thread = nil 
      @send_thread.kill if @send_thread
      @send_thread = nil
      @driver.close 
    end

    def send(message)
      message[:id] = message_id
      @send_queue << message.to_json
    end

    alias_method :<<, :send

    def start
      launch_connection_thread
      launch_send_thread
      wait_for_open if @open_wait_timeout
    end

    private

    def poll_websocket
      if IO.select([@driver_client.socket], nil, nil, @select_timeout)
        data = @driver_client.socket.readpartial 4096
        @driver.parse data unless data.nil? || data.empty?
      end
      tdiff = Time.new.to_i - @last_activity
      if Time.new.to_i - @last_activity > @ping_threshold
        @driver.ping
        @last_activity = Time.new.to_i
      end
    end

    def connect_to_slack
      return if @connection_status == :open
      @connection_status = :connecting
      socket = OpenSSL::SSL::SSLSocket.new(TCPSocket.new(@url.sub(%r{.*//([^/]*)/.*}, '\1'), 443))
      @driver_client = WebSocketDriverClient.new(
        @url,
        socket
      )
      socket.connect
      @driver = WebSocket::Driver.client @driver_client
      register_driver_events
      @last_activity = Time.now.to_i
      @driver.start
    end

    def get_initial_url(token: nil)
      response_body = JSON.parse req = Net::HTTP.post_form(
        URI(SLACK_RTM_START_URL), 
        token: token
      ).body
      if response_body['ok']
        response_body['url']
      else
        raise ArgumentError, "Slack error: #{body['error']}"
      end
    end

    def launch_connection_thread
      @connection_thread = Thread.new do
        connect_to_slack
        loop do
          if @connection_status == :closed
            sleep @select_timeout
          else
            poll_websocket 
          end
        end
      end
      @connection_thread.abort_on_exception = true
    end

    def launch_send_thread
      @send_thread = Thread.new do
        loop do
          message = @send_queue.shift
          log "WebSocket::Driver send #{message}"
          sleep 0.01 until @connection_status == :open
          @driver.text message
        end
      end
      @send_thread.abort_on_exception = true
    end
    
    def message_id
      @message_id_mutex = Mutex.new unless defined? @message_id_mutex
      @message_id_mutex.synchronize {
        @message_id = 0 unless defined? @message_id
        @message_id += 1
      }
      @message_id
    end       

    def register_driver_events 
      register_driver_open
      register_driver_close
      register_driver_error
      register_driver_message
    end

    def register_driver_close
      @driver.on :close do |event|
        log "WebSocket::Driver received a close event"
        @event_handlers[:close].call if @event_handlers[:close]
        @connection_status = :closed
        connect_to_slack if @auto_reconnect
      end
    end

    def register_driver_error
      @driver.on :error do |event|
        @last_activity = Time.new.to_i
        log "WebSocket::Driver received an error"
        @event_handlers[:error].call if @event_handlers[:error]
      end
    end

    def register_driver_message
      @driver.on :message do |event|
        data = JSON.parse event.data
        @last_activity = Time.new.to_i
        log "WebSocket::Driver received an event with data: #{data}"
        case data['type']
        when 'hello'
          @connection_status = :open
        when 'reconnect_url'
          @driver_client.url = data['url'].to_s
          log "#{CLASS} message URL Updated #{data['url']}"
        else
          @event_handlers[:message].call data unless @event_handlers[:message].nil?
        end
      end
    end

    def register_driver_open
      @driver.on :open do
        @connection_status = :initializing
        @last_activity = Time.new.to_i
        log "WebSocket::Driver :open"
        @event_handlers[:open].call if @event_handlers[:open]
      end
    end

    def log(message)
      return unless @debug
      @logger ||= Logger.new(STDOUT)
      @logger.info message
    end

    def wait_for_open
      start_time = Time.new.to_i
      sleep @select_timeout while @connection_status != :open &&
        (Time.new.to_i - start_time < @open_wait_timeout)
      raise StandardError, "Timed out waiting for open" unless @connection_status == :open
    end

  end

  class WebSocketDriverClient
    attr_accessor :url, :socket

    def initialize(url, socket)
      @url = url
      @socket = socket
    end

    def write(*args)
      @socket.write(*args)
    end
  end

end
