# encoding: UTF-8

require 'therubyracer'
require 'multi_json'
require 'digest/sha1'

class KiCompiler

  def initialize
    context = V8::Context.new

    context.eval %Q{
      this.__modules = {};
      this.__loaded = {};
      this.__specs = {};
      this.__texts = {};
      this.__macrocache = {};
      this.__define = function (name, deps, factory) {
        __specs[name] = ({ deps: deps, factory: factory });
      }
    }

    parse(context, "ki")
    round = 1
    spec_count = context.eval("this.__specs").count

    while true do
      parse_step(context)

      new_spec_count = context.eval("this.__specs").count
      break if new_spec_count == spec_count
      spec_count = new_spec_count

      puts "\n========== Round #{round} ==============="
      print_specs(context)
      round = round + 1
    end

    puts "Should now bless all those specs."

    context.eval %Q{
      Object.keys(this.__specs).forEach(function (name) {
        __modules[name] = {};
      });
    }

    bless(context, "ki")

    # load source map support too.
    context.eval(%Q{
        this.window = this;
                 })

    context.load(resource_path("source-map.js"));

    context.eval(%Q{
        delete this.window;
                 })

    @ki_core = File.read(resource_path("ki.sjs"))
    @context = context
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
                  pathname.relative_path_from(Rails.root).dirname
                end

    # don't forget to gitignore that!
    map_dir = Rails.root.join("public/" + Rails.configuration.assets.prefix, "source_maps", rel_path)
    map_dir.mkpath

    map_file    = map_dir.join("#{clean_name}.map")
    ki_file = map_dir.join("#{clean_name}.js.ki")

    # the ki compiler includes the sourceMappingURL comment itself,
    # but it requires a correct 'mapfile' argument.
    ret = _ki_compile(source, macros_source,
                      :filename => "/" + ki_file.relative_path_from(Rails.root.join("public")).to_s,
                      :mapfile =>  "/" + map_file.relative_path_from(Rails.root.join("public")).to_s)

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

  def escape(input)
    MultiJson.dump(input)
  end

  def digest(input)
    Digest::SHA1.hexdigest input
  end

  def _ki_compile(source, macros_source, options = {})
    macros = @context.eval %Q{__modules.ki.parseMacros(#{escape(macros_source)})}
    macros_digest = digest(macros);
    puts "Macros digest #{macros_digest} for #{options[:filename]}"

    js = []
    js << "var sweet = __modules.sweet;"
    js << "var ki = __modules.ki;"
    js << "var options = {};"
    js << "var source = #{escape(source)};"

    if @context.eval %Q{!!__macrocache[#{escape(macros_digest)}]}
      puts "Cache hit!!!"
      js << "options.modules = __macrocache[#{escape(macros_digest)}];"
    else
      puts "Cache miss :("
      js << "var modules = sweet.loadModule(ki.joinModule(#{escape(macros_source)}, #{escape(@ki_core)}));"
      js << "__macrocache[#{escape(macros_digest)}] = modules;"
      js << "options.modules = modules;"
    end

    if options[:filename] && options[:mapfile]
      js << "options.filename = #{escape(options[:filename])};"
      js << "options.mapfile = #{escape(options[:mapfile])};"
      js << "options.sourceMap = true;"
    else
    end

    js << "ki.compile(source, options);"
    @context.eval js.join("\n")
  end

  def normalize_spec(spec)
    return spec if spec.start_with? "text!"
    spec.gsub(/\.\//, '')
  end

  def resource_path(name)
    File.expand_path("../resources/#{name}", __FILE__)
  end

  def parse_text(context, name)
    # TODO: does this leak fds?
    source = File.open(resource_path(name), "r:UTF-8").read

    context.eval %Q{
      this.__texts["#{name}"] = #{MultiJson.dump(source)}; 
    }
  end

  def parse(context, name)
    path = resource_path("#{name}.js")

    context.eval %Q{
      this.define_called = false;

      this.define = function (a, b, c) {
        called = true;

        if (typeof a === 'string') {
          // named AMD module
          __define(a, b, c);
        } else {
          // not named, use the provided name.
          __define("#{name}", a, b)
        }
      }
      this.define.amd = true;
    }
    context.load path

    context.eval %Q{
      if (!this.called) {
        __define("#{name}", [], null)
      }

      delete this.called;
      delete this.define;
    }
  end

  def spec_defined?(context, name)
    context.eval %Q{this.__specs["#{name}"];}
  end

  def parse_step(context)
    specs = context.eval "this.__specs;"
    specs.each do |name, spec|
      spec.deps.each do |dep|
        next if dep == 'exports'
        if dep.start_with? 'text!'
          text_name = dep[5..-1]
          if text_name.start_with? './'
            text_name = text_name[2..-1]
          end
          puts "Parsing text #{text_name} (because of #{name})"
          parse_text(context, text_name)
        else
          dep = normalize_spec(dep)
          unless spec_defined?(context, dep)
            puts "Parsing #{dep} (because of #{name})..."
            parse(context, dep)
          end
        end
      end
    end
  end

  def print_specs(context)
    specs = context.eval("this.__specs");
    specs.each do |name, spec|
      deps = []
      spec[:deps].each do |dep|
        dep = normalize_spec(dep)
        deps << dep
      end
      puts "#{name.ljust(20)} => #{deps.join(' ')}"
    end
  end

  def blessed?(context, name)
    context.eval %Q{!!this.__loaded["#{name}"]}
  end

  def deps_satisfied?(context, deps)
    deps.all? do |dep|
      if dep == 'exports'
        true
      elsif dep.start_with? 'text!'
        # TODO: text loading.
        true
      else
        blessed?(context, dep)
      end
    end
  end

  def bless_candidates(context)
    candidates = []
    specs = context.eval("this.__specs");
    specs.each do |name, spec|
      next if blessed?(context, name)
      next unless deps_satisfied?(context, spec[:deps])
      candidates << name
    end

    candidates
  end

  def bless(context, name)
    return if name == 'exports'
    return if name.start_with? 'text!'

    name = normalize_spec(name)
    return if blessed?(context, name)

    context.eval %Q{
      this.__loaded["#{name}"] = true;
    }

    spec = context.eval %Q{this.__specs["#{name}"]}
    puts "Checking deps of #{name}..."
    spec[:deps].each do |dep|
      bless(context, dep)
    end

    puts "Blessing #{name}"

    context.eval %Q{
      var exports = __modules["#{name}"];
      var spec = __specs["#{name}"];

      if (spec.factory) {
        var deps = [];
        for (var i = 0; i < spec.deps.length; i++) {
          var dep = spec.deps[i];
          var tokens = dep.match(/^(text!)?(\\.\\/)?(.*)$/);
          var is_text = !!tokens[1];
          var slug = tokens[3];

          if (is_text) {
            var text = __texts[slug];
            if (text) { deps.push(text) }
            else      { throw new Error("Text resource not found: " + slug);}
          } else if (slug == 'exports') {
            deps.push(exports);
          } else if (slug == 'underscore') {
            deps.push(_);
          } else {
            var module = __modules[slug];
            if (module) { deps.push(module) }
            else        { throw new Error("Module resource not found: " + slug);}
          }
        }
        spec.factory.apply(null, deps);
      }
    }
  end


end

