# encoding: UTF-8

require 'therubyracer'
require 'multi_json'

class KiCompiler

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

  def initialize
    context = V8::Context.new

    context.eval %Q{
      this.__modules = {};
      this.__loaded = {};
      this.__specs = {};
      this.__texts = {};
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

    macros_source = File.read(resource_path("ki.sjs"))

    context.eval(%Q{
        var ki = __modules['ki'];
        var sweet = __modules['sweet'];
        this.__ki_modules = sweet.loadModule(#{MultiJson.dump(macros_source)});
    })

    @context = context
  end

  def compile(source, filename = "")
    @context.eval %Q{
      __modules.ki.compile(
        #{MultiJson.dump(source)},
      {filename: "#{filename}",
       modules: __ki_modules}).code
    }
  end

end

