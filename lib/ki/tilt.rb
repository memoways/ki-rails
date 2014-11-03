
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
        pathname = scope.respond_to?(:pathname) ? scope.pathname : nil
        compiler.compile(data, :pathname => pathname) + "\n"
      end
    end
  end
end

