
require 'tilt'
require 'ki/ki_compiler'

module Ki
  module Rails
    class Template < ::Tilt::Template
      def prepare
      end

      def compiler
        @@compiler ||= Ki::Compiler.new
      end

      def evaluate(scope, locals, &block)
        dependencies = scope._dependency_assets.to_a
        pathname = scope.respond_to?(:pathname) ? scope.pathname : nil
        ki_source = data
        macros_source = dependencies.map { |x| File.read(x) }.join("\n")

        macros_digest = compiler.parse_macros(macros_source);
        return compiler.compile(ki_source, macros_digest)[:code] + "\n" if pathname.nil?

        sourcemap_info = make_sourcemap(pathname)
        result = compiler.compile(ki_source, macros_digest,
                                  :ki_path  => sourcemap_info[:ki_path],
                                  :map_path => sourcemap_info[:map_path])
        write_sourcemap(sourcemap_info, result[:sourceMap], ki_source)
        result[:code] + "\n"
      end

      def make_sourcemap(pathname)
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

        map_file = map_dir.join("#{clean_name}.map")
        ki_file  = map_dir.join("#{clean_name}.js.ki")

        return {:ki_path =>  "/" + ki_file.relative_path_from(::Rails.root.join("public")).to_s,
                :map_path => "/" + map_file.relative_path_from(::Rails.root.join("public")).to_s,
                :ki_file => ki_file,
                :map_file => map_file}
      end

      def write_sourcemap(sourcemap_info, map, ki)
        begin
          sourcemap_info[:map_file].open('w') {|f| f.puts map}
          sourcemap_info[:ki_file].open('w')  {|f| f.puts ki}
        rescue Errno::EACCESS
          # we won't have sourcemaps if we can't write them, but it's no reason
          # to crash the app.
        end
      end
    end
  end
end

