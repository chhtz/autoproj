require 'rbconfig'
require 'autoproj/cli/inspection_tool'
module Autoproj
    module CLI
        class Envsh < InspectionTool
            attr_predicate :watch?
            attr_reader :options
            attr_reader :source_packages
            attr_reader :notifier
            attr_reader :watchers
            def validate_options(unused, options = {})
                _, options = super(unused, options)
                @watchers = []
                @watch = options[:watch]
                @options = options
                options
            end

            def update_workspace(create = false)
                if create
                    new_ws = Autoproj::Workspace.new(ws.root_dir)
                    new_ws.set_as_main_workspace
                    @ws = new_ws
                end
                initialize_and_load
                shell_helpers = options.fetch(:shell_helpers,
                                              ws.config.shell_helpers?)
                @source_packages, = finalize_setup([])
                export_env_sh(shell_helpers: shell_helpers)
            end

            def callback
                puts 'Workspace changed...'
                stop_watchers
                update_workspace(true)
                start_watchers
            end

            def create_file_watcher(file)
                watchers << notifier.watch(file, :modify) do |e|
                    delete_watcher(e.watcher) if e.flags.include? :ignored
                    callback
                end
            end

            def create_dir_watcher(dir, *files, recursive: false)
                opt_args = %i[move create delete]
                opt_args << :recursive if recursive

                watchers << notifier.watch(dir, *opt_args) do |e|
                    delete_watcher(e.watcher) if e.flags.include? :ignored
                    file_name = File.basename(e.absolute_name)
                    next unless files.any? { |regex| file_name =~ regex }
                    callback
                end
            end

            def delete_watcher(watcher)
                watchers.delete(watcher)
            end

            def create_src_pkg_watchers
                source_packages.each do |pkg_name|
                    pkg = ws.manifest.find_autobuild_package(pkg_name)
                    manifest_file = File.join(pkg.srcdir, 'manifest.xml')

                    next unless File.exist? pkg.srcdir
                    create_dir_watcher(pkg.srcdir, /^manifest.xml$/)
                    next unless File.exist? manifest_file
                    create_file_watcher(manifest_file)
                end
            end

            def create_autobuild_watchers(dir)
                Dir[File.join(dir, '*.autobuild')].each do |file|
                    create_file_watcher(file)
                end
            end

            def create_manifests_watchers(dir)
                Dir[File.join(dir, '**/*.xml')].each do |file|
                    create_file_watcher(file)
                end
            end

            def create_ruby_watchers(dir)
                Dir[File.join(dir, '**/*.rb')].each do |file|
                    create_file_watcher(file)
                end
            end

            def create_pkg_set_watchers
                ws.manifest.each_package_set do |pkg_set|
                    pkg_set_dir = pkg_set.raw_local_dir
                    create_dir_watcher(pkg_set_dir,
                                       /^manifests$/,
                                       /^*\.autobuild$/,
                                       /^*\.rb$/)

                    create_autobuild_watchers(pkg_set_dir)
                    create_ruby_watchers(pkg_set_dir)

                    manifests_dir = File.join(pkg_set_dir, 'manifests')
                    next unless File.exist?(manifests_dir)
                    create_manifests_watchers(manifests_dir)
                    create_dir_watcher(manifests_dir, /^*\.xml$/,
                                       recursive: true)
                end
            end

            def start_watchers
                create_file_watcher(ws.config.path)
                create_file_watcher(ws.manifest_file_path)
                create_src_pkg_watchers
                create_pkg_set_watchers
            end

            def stop_watchers
                watchers.each(&:close)
                watchers.clear
            end

            def assert_watchers_available
                return if RbConfig::CONFIG['target_os'] =~ /linux/
                puts 'error: Workspace watching not available on this platform'
                exit 1
            end

            def setup_notifier
                assert_watchers_available

                require 'rb-inotify'
                @notifier = INotify::Notifier.new
            end

            def run(*, **)
                update_workspace
                return unless watch?

                setup_notifier
                start_watchers
                puts 'Watching workspace, press ^C to quit...'
                notifier.run
            rescue Interrupt
                puts 'Exiting...'
            ensure
                stop_watchers
            end
        end
    end
end
