# encoding: UTF-8

require 'therubyracer'
require 'digest/sha1'
require 'ki/amd_loader'

module Ki
  class Compiler

    def initialize
      @amd = Ki::AmdLoader.new
      @amd.load("ki")

      # set up a cache for macro compilation
      @amd.eval("$kir.macro_cache = {}")

      # store the ki core macros inside V8.
      ki_core = File.read(@amd.resource_path("ki.sjs"))
      @amd.eval("$kir.ki_core = #{@amd.escape(ki_core)}")

      # load source map support - needs access to 'window' because
      # it's not a well-behaved AMD module.
      @amd.eval("this.window = this")
      @amd.load("source-map")
      @amd.eval("delete this.window")
    end

    def parse_macros(input)
      macros_source = @amd.eval %Q{$kir.modules.ki.exports.parseMacros(#{@amd.escape(input)})}
      macros_digest = digest(macros_source)

      if @amd.eval %Q{!$kir.macro_cache[#{@amd.escape(macros_digest)}]}
        # cache miss
        @amd.eval %Q{
          var sweet = $kir.modules.sweet.exports;
          var ki = $kir.modules.ki.exports;
          var macros_source = #{@amd.escape(macros_source)};
          var full_source = $kir.ki_core.replace('/*__macros__*/', macros_source);
          var modules = sweet.loadModule(full_source);
          $kir.macro_cache[#{@amd.escape(macros_digest)}] = modules;
        }
      else
        # cache hit
      end
      macros_digest
    end

    def compile(source, macros_digest, options = {})
      js = []
      js << "var sweet = $kir.modules.sweet.exports;"
      js << "var ki = $kir.modules.ki.exports;"
      js << "var options = {};"
      js << "var source = #{@amd.escape(source)};"
      js << "options.modules = $kir.macro_cache[#{@amd.escape(macros_digest)}];"

      if options[:ki_path] && options[:map_path]
        js << "options.filename = #{@amd.escape(options[:ki_path])};"
        js << "options.mapfile = #{@amd.escape(options[:map_path])};"
        js << "options.sourceMap = true;"
      else
      end

      js << "ki.compile(source, options);"
      @amd.eval js.join("\n")
    end

    private

    def digest(input)
      Digest::SHA1.hexdigest input
    end
  end
end

