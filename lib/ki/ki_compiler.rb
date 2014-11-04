# encoding: UTF-8

require 'therubyracer'
require 'digest/sha1'
require 'ki/amd_loader'

module Ki
  class Compiler

    def initialize
      @amd = Ki::AmdLoader.new
      @amd.load("ki")
      @ki_core = File.read(@amd.resource_path("ki.sjs"))
      @amd.eval("$kir.macro_cache = {}")

      # load source map support too.
      @amd.eval("this.window = this")
      @amd.load("source-map")
      @amd.eval("delete this.window")
    end

    def compile(source, options = {})
      pathname = options[:pathname]

      # macros can be defined anywhere in required files, but
      # they must be available, so Sweet.js has to parse them.
      # Yes, even in development where Sprockets serves separate files.
      macros_source = if options[:dependencies]
                        options[:dependencies].map { |x| File.read(x) }.join("\n")
                      else
                        source
                      end

      # no source map support? too bad.
      return _ki_compile(source, macros_source)[:code] if pathname.nil?

      # gleefully stolen from https://github.com/markbates/coffee-rails-source-maps
      clean_name = pathname.basename.to_s.split(".").first

      rel_path = if pathname.to_s.start_with?(Bundler.bundle_path.to_s)
                    Pathname('bundler').join(pathname.relative_path_from(Bundler.bundle_path)).dirname
                  else
                    pathname.relative_path_from(::Rails.root).dirname
                  end

      # don't forget to gitignore that!
      map_dir = ::Rails.root.join("public/" + ::Rails.configuration.assets.prefix, "source_maps", rel_path)
      map_dir.mkpath

      map_file    = map_dir.join("#{clean_name}.map")
      ki_file = map_dir.join("#{clean_name}.js.ki")

      # the ki compiler includes the sourceMappingURL comment itself,
      # but it requires a correct 'mapfile' argument.
      ret = _ki_compile(source, macros_source,
                        :filename => "/" + ki_file.relative_path_from(::Rails.root.join("public")).to_s,
                        :mapfile =>  "/" + map_file.relative_path_from(::Rails.root.join("public")).to_s)

      begin
        # write source map + original code, if we can.
        map_file.open('w') {|f| f.puts ret[:sourceMap]}
        ki_file.open('w')  {|f| f.puts source }
      rescue Errno::EACCESS
        # we won't have sourcemaps if we can't write them, but it's no reason
        # to crash the app.
      end

      return ret[:code]
    end

    private

    def digest(input)
      Digest::SHA1.hexdigest input
    end

    def _ki_compile(source, macros_source, options = {})
      macros = @amd.eval %Q{$kir.modules.ki.exports.parseMacros(#{@amd.escape(macros_source)})}
      macros_digest = digest(macros);
      puts "Macros digest #{macros_digest} for #{options[:filename]}"

      js = []
      js << "var sweet = $kir.modules.sweet.exports;"
      js << "var ki = $kir.modules.ki.exports;"
      js << "var options = {};"
      js << "var source = #{@amd.escape(source)};"

      if @amd.eval %Q{!!$kir.macro_cache[#{@amd.escape(macros_digest)}]}
        puts "Cache hit!!!"
        js << "options.modules = $kir.macro_cache[#{@amd.escape(macros_digest)}];"
      else
        puts "Cache miss :("
        js << "var modules = sweet.loadModule(ki.joinModule(#{@amd.escape(macros_source)}, #{@amd.escape(@ki_core)}));"
        js << "$kir.macro_cache[#{@amd.escape(macros_digest)}] = modules;"
        js << "options.modules = modules;"
      end

      if options[:filename] && options[:mapfile]
        js << "options.filename = #{@amd.escape(options[:filename])};"
        js << "options.mapfile = #{@amd.escape(options[:mapfile])};"
        js << "options.sourceMap = true;"
      else
      end

      js << "ki.compile(source, options);"
      @amd.eval js.join("\n")
    end
  end
end

