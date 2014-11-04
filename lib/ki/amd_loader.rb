
require 'multi_json'

module Ki
  class AmdLoader

    DEBUG = false

    def initialize
      @context = V8::Context.new

      @context.eval %Q{
        this.$kir = {
          modules: {},

          define: function (name, deps, factory) {
            return $kir.modules[name] = {
              deps: deps,
              factory: factory,
              exports: {}
            };
          }
        }
      }
    end

    def context
      @context
    end

    def eval(source)
      @context.eval(source)
    end

    def spec_loaded?(spec)
      @context.eval("$kir.modules[#{escape(spec.name)}] != null")
    end

    def load(spec_input)
      spec = parse_spec(spec_input)
      debug "Loading #{spec.name}"

      if spec.text?
        path = resource_path(spec.name)
        text_content = File.read(path);
        @context.eval %Q{
          $kir.define(#{escape(spec.name)}, [], null).exports = #{escape(text_content)};
        }
        return
      end

      path = resource_path(spec.name + ".js")

      # use globals so we can use V8::Context.load
      # and retain stack trace information.
      # the alternative is to eval the code, but
      # it makes debugging a lot harder.
      
      @context.eval %Q{
        this.$define_called = false;
        this.define = function (a, b, c) {
          $define_called = true; 
          if (typeof a === 'string') {
            $kir.define(a, b, c);
          } else {
            $kir.define(#{escape(spec.name)}, a, b);
          }
        }
        this.define.amd = true;
      }

      @context.load path

      mod = @context.eval %Q{
        var name = #{escape(spec.name)};

        if (!$define_called) {
          $kir.define(name, [], null);
        }

        delete this.$define_called;
        delete this.define;
        $kir.modules[name];
      }

      if mod[:factory].nil?
        # non-AMD modules workaround
        case spec.name
        when 'underscore'
          debug "Underscore workaround."
          @context.eval "$kir.modules[#{escape(spec.name)}].exports = this._;"
        end

        # in any case, we have no factory to run.
        return
      end

      js = []
      js << "var deps = ["

      mod[:deps].each do |dep|
        dep_spec = parse_spec(dep)
        if dep_spec.exports?
          js << "$kir.modules[#{escape(spec.name)}].exports, "
        else
          debug "#{spec.name} => #{dep_spec.name}"
          unless spec_loaded?(dep_spec)
            load(dep_spec.input)
          end
          js << "$kir.modules[#{escape(dep_spec.name)}].exports, "
        end
      end
      js << "];"

      js << "$kir.modules[#{escape(spec.name)}].factory.apply(null, deps);"

      # actually call the factory!
      debug "Calling the factory of #{spec.name}"
      @context.eval js.join("\n")

    end

    def resource_path(name)
      File.expand_path("../resources/#{name}", __FILE__)
    end

    def escape(input)
      MultiJson.dump(input)
    end

    private

    def parse_spec(spec_input)
      _, text, _, name = /^(text!)?(\.\/)?(.*)$/.match(spec_input).to_a
      Struct.
        new(:input, :name, :exports?, :text?).
        new(spec_input, name, name == 'exports', !!text)
    end

    def debug(*args)
      puts(*args) if DEBUG
    end

  end
end

