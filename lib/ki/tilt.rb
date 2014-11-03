
require 'tilt'
require 'ki/ki_compiler'

module Ki
  module Rails
    class Template < ::Tilt::Template
      def prepare
      end

      def compiler
        @@compiler ||= KiCompiler.new
      end

      def evaluate(scope, locals, &block)
        compiler.compile(data)
      end
    end
  end
end

