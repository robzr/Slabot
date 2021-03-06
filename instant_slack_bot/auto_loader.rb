# InstantSlackBot::AutoLoader monitors a directory in a background thread for
#   files that are added, deleted or changed and loads a public queue (@changes)
#   with a description of the event

require 'pp'
require 'set'

module InstantSlackBot #:nodoc:
  class AutoLoader
    CLASS = 'InstantSlackBot::AutoLoader'
    attr_accessor :changes

    def initialize(
      debug: nil,
      directory: '.', 
      glob: '*.rb', 
      master: nil, 
      refresh: 0.5
    )
      @debug = debug
      @glob = "#{directory}/#{glob}"
      @master = master
      @refresh = refresh

      @bots = {}
      @changes = Queue.new
      @files = {}
      @watcher_thread = launch_watcher_thread
    end

    private

    def compare_directory
      new_files = load_directory
      @files.each do |file_name, stat|
        if new_files.key? file_name
          file_changed file_name unless new_files[file_name] == stat
          new_files.delete(file_name) 
        else
          file_deleted file_name
        end
      end
      new_files.each do |file_name, stat|
        file_added file_name
      end
    end

    def file_added(file)
      @files[file] = file_stat file
      @changes << { action: :added, file: file }
    end

    def file_changed(file)
      @files[file] = file_stat file
      @changes << { action: :changed, file: file }
    end

    def file_deleted(file)
      @files.delete(file)
      @changes << { action: :deleted, file: file }
    end

    def file_stat(file)
      stat = File.stat(file)
      {
        size: stat.size,
        mtime: stat.mtime
      }
    end

    def get_module_name(file)
      file.gsub(/.*\//, '')
        .sub(/\.rb$/, '')
        .split(/_/)
        .map { |word| word.capitalize } 
        .join
    end

    def launch_watcher_thread
      watcher_thread = Thread.new do
        loop do 
          time_starting = Time.now.to_f
          compare_directory
          update_master if @master
          delay = @refresh - (Time.now.to_f - time_starting)
          sleep delay if delay > 0
        end
      end
      watcher_thread.abort_on_exception = true
      watcher_thread
    end

    def load_directory
      files = {}
      Dir[@glob].each do |file|
        files[file] = file_stat file
      end
      files
    end

    def load_file(file)
      load file
      true
    rescue SyntaxError => msg
      puts "#{CLASS} syntax error in #{file}, skipping load"
      puts "#{msg.to_s.gsub(/^/, ' -> ')}"
      false
    end

    def master_add(file)
      return false unless load_file file
      @bots[file] = []
      module_name = get_module_name file
      eval("#{module_name}.constants").each do |class_name|
        class_path = "#{module_name}::#{class_name.to_s}"
        if(eval("#{class_path}.class.name == 'Class'") &&
           eval("#{class_path}.ancestors.include? " +
                "InstantSlackBot::Bot"))
          @bots[file] << eval("#{class_path}.new")
          puts "#{CLASS} adding #{class_path} #{@bots[file][-1].id}" if @debug
          @master << @bots[file]
        end
      end
    rescue Exception => msg
      print_load_error(file: file, msg: msg)
    end

    def print_load_error(file: nil, msg: nil)
      puts "#{CLASS} Error: #{file}"
      puts "  Detail: #{msg}"
      puts msg.backtrace
        .select { |bt| bt !~ /\/auto_loader.rb:/ }
        .join("\n")
        .gsub(/^/, '  -> ')
    end

    def master_delete(file)
      return unless @bots.key? file
      @bots[file].each do |bot|
        puts "#{CLASS} deleting Bot: #{bot.class.to_s} #{bot.id}" if @debug
        @master.delete(bot.id)
      end
      module_name = get_module_name(file)
      eval("#{module_name}.constants").each do |class_name|
        eval "#{module_name}.send(:remove_const, '#{class_name}')"
      end
      @bots.delete(file)
    rescue Exception => msg
      puts "#{CLASS}#master_delete - error #{msg}"
    end

    def update_master(master = @master)
      while @changes.length > 0
        change = @changes.shift
        case change[:action]
        when :added
          master_add change[:file]
        when :deleted
          master_delete change[:file]
        when :changed
          master_delete change[:file]
          master_add change[:file]
        end
      end
    end

  end
end
