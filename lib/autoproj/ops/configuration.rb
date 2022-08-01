require "rgl/adjacency"
require "rgl/dot"
require "rgl/topsort"

module Autoproj
    module Ops
        #--
        # NOTE: indentation is wrong to let git track the history properly
        #+++

        # PackageSetHierachy be used to build the hierarchy of package set
        # imports, as directed acyclic graph (DAG)
        # so that they can be (topologically) sorted according to their
        # dependencies
        class PackageSetHierarchy
            attr_reader :dag

            def initialize(package_sets, root_pkg_set)
                @dag = RGL::DirectedAdjacencyGraph.new

                package_sets.each do |p|
                    p.imports.each do |dep|
                        @dag.add_edge dep, p
                    end
                end

                @dag.add_vertex root_pkg_set
                import_order = root_pkg_set.imports.to_a
                import_order.each_with_index do |p, index|
                    if index + 1 < import_order.size
                        @dag.add_edge p, import_order[index + 1]
                        @dag.add_edge p, root_pkg_set
                    end
                end
            end

            def verify_acyclic
                return if @dag.acyclic?

                Autoproj.fatal "The package sets form (a) cycle(s)"
                @dag.cycles.each_with_index do |cycle, index|
                    Autoproj.fatal "== Cycle #{index}"
                    (cycle + cycle[0, 1]).each_cons(2) do |a, b|
                        if b.imports.include?(a)
                            Autoproj.fatal "  #{b.name} depends on #{a.name} in its source.yml"
                        else
                            Autoproj.fatal "  #{b.name} is after #{a.name} in the package_sets section of the manifest"
                        end
                    end
                end

                raise ConfigError.new "cycles in package set dependencies"
            end

            # Flatten the hierarchy, a establish a sorting
            def flatten
                @dag.topsort_iterator.to_a
            end

            # Write the hierarchy to an image (png) file
            def to_png(path)
                @dag.write_to_graphic_file("png", path.gsub(".png", ""))
            end
        end

        # Implementation of the operations to manage the configuration
        class Configuration
            attr_reader :ws

            # The autoproj install we should update from (if any)
            #
            # @return [nil,InstallationManifest]
            attr_reader :update_from

            # The path in which remote package sets should be exposed to the
            # user
            #
            # @return [String]
            def remotes_dir
                ws.remotes_dir
            end

            # The path in which remote package sets should be exposed to the
            # user
            #
            # @return [String]
            def remotes_user_dir
                File.join(ws.config_dir, "remotes")
            end

            # The path to the main manifest file
            #
            # @return [String]
            def manifest_path
                ws.manifest_file_path
            end

            # @param [Manifest] manifest
            # @param [Loader] loader
            # @option options [InstallationManifest] :update_from
            #   another autoproj installation from which we
            #   should update (instead of the normal VCS)
            def initialize(workspace, update_from: nil)
                @ws = workspace
                @update_from = update_from
                @remote_update_message_displayed = false
            end

            # Imports or updates a source (remote or otherwise).
            #
            # See create_autobuild_package for informations about the arguments.
            def update_configuration_repository(vcs, name, into,
                only_local: false,
                reset: false,
                retry_count: nil)

                fake_package = Tools.create_autobuild_package(vcs, name, into)
                if update_from
                    # Define a package in the installation manifest that points to
                    # the desired folder in other_root
                    relative_path = Pathname.new(into)
                                            .relative_path_from(Pathname.new(ws.root_dir)).to_s
                    other_dir = File.join(update_from.path, relative_path)
                    if File.directory?(other_dir)
                        update_from.packages.unshift(
                            InstallationManifest::Package.new(fake_package.name, other_dir, File.join(other_dir, "install"))
                        )
                    end

                    # Then move the importer there if possible
                    if fake_package.importer.respond_to?(:pick_from_autoproj_root)
                        unless fake_package.importer.pick_from_autoproj_root(fake_package, update_from)
                            fake_package.update = false
                        end
                    else
                        fake_package.update = false
                    end
                end
                fake_package.importer.retry_count = retry_count if retry_count
                fake_package.import(only_local: only_local, reset: reset)
            rescue Autobuild::ConfigException => e
                raise ConfigError.new, "cannot import #{name}: #{e.message}", e.backtrace
            end

            # Update the main configuration repository
            #
            # @return [Boolean] true if something got updated or checked out,
            #   and false otherwise
            def update_main_configuration(keep_going: false, checkout_only: !Autobuild.do_update, only_local: false, reset: false, retry_count: nil)
                return [] if checkout_only && File.exist?(ws.config_dir)

                update_configuration_repository(
                    ws.manifest.vcs, "autoproj main configuration", ws.config_dir,
                    only_local: only_local, reset: reset, retry_count: retry_count
                )
                []
            rescue Interrupt
                raise
            rescue Exception => e
                if keep_going
                    [e]
                else
                    raise e
                end
            end

            # Update or checkout a remote package set, based on its VCS definition
            #
            # @param [VCSDefinition] vcs the package set VCS
            # @return [Boolean] true if something got updated or checked out,
            #   and false otherwise
            def update_remote_package_set(vcs,
                checkout_only: !Autobuild.do_update,
                only_local: false,
                reset: false,
                retry_count: nil)

                raw_local_dir = PackageSet.raw_local_dir_of(ws, vcs)
                return if checkout_only && File.exist?(raw_local_dir)

                # name_of does minimal validation of source.yml, so do it here
                # even though we don't really need it
                name = PackageSet.name_of(ws, vcs, ignore_load_errors: true)
                ws.install_os_packages([vcs.type], all: nil)
                update_configuration_repository(
                    vcs, name, raw_local_dir,
                    only_local: only_local,
                    reset: reset,
                    retry_count: retry_count
                )
            end

            # Create the user-visible directory for a remote package set
            #
            # @param [VCSDefinition] vcs the package set VCS
            # @return [String] the full path to the created user dir
            def create_remote_set_user_dir(vcs)
                name = PackageSet.name_of(ws, vcs)
                raw_local_dir = PackageSet.raw_local_dir_of(ws, vcs)
                FileUtils.mkdir_p(remotes_user_dir)
                symlink_dest = File.join(remotes_user_dir, name)

                # Check if the current symlink is valid, and recreate it if it
                # is not
                if File.symlink?(symlink_dest)
                    dest = File.readlink(symlink_dest)
                    if dest != raw_local_dir
                        FileUtils.rm_f symlink_dest
                        Autoproj.create_symlink(raw_local_dir, symlink_dest)
                    end
                else
                    FileUtils.rm_f symlink_dest
                    Autoproj.create_symlink(raw_local_dir, symlink_dest)
                end

                symlink_dest
            end

            def load_package_set(vcs, options, imported_from)
                pkg_set = PackageSet.new(ws, vcs)
                pkg_set.auto_imports = options[:auto_imports]
                pkg_set.load_description_file
                if imported_from
                    pkg_set.imported_from << imported_from
                    imported_from.imports << pkg_set
                end
                pkg_set
            end

            def queue_auto_imports_if_needed(queue, pkg_set, root_set)
                if pkg_set.auto_imports?
                    pkg_set.each_raw_imported_set do |import_vcs, import_options|
                        vcs_overrides_key = import_vcs.overrides_key
                        import_vcs = root_set.resolve_overrides("pkg_set:#{vcs_overrides_key}", import_vcs)
                        queue << [import_vcs, import_options, pkg_set]
                    end
                end
                queue
            end

            # Load the package set information
            #
            # It loads the package set information as required by {manifest} and
            # makes sure that they are either updated (if Autobuild.do_update is
            # true), or at least checked out.
            #
            # @yieldparam [String] osdep the name of an osdep required to import the
            #   package sets
            def load_and_update_package_sets(root_pkg_set,
                only_local: false,
                checkout_only: !Autobuild.do_update,
                keep_going: false,
                reset: false,
                retry_count: nil)
                package_sets = [root_pkg_set]
                by_repository_id = Hash.new
                by_name = Hash.new
                failures = Array.new

                required_remotes_dirs = Array.new

                queue = queue_auto_imports_if_needed(Array.new, root_pkg_set, root_pkg_set)
                until queue.empty?
                    vcs, import_options, imported_from = queue.shift
                    repository_id = vcs.overrides_key
                    if (already_processed = by_repository_id[repository_id])
                        already_processed_vcs, already_processed_from, pkg_set = *already_processed
                        if (already_processed_from != root_pkg_set) && (already_processed_vcs != vcs)
                            Autoproj.warn "already loaded the package set from #{already_processed_vcs} from #{already_processed_from.name}, this overrides different settings (#{vcs}) found in #{imported_from.name}"
                        end

                        if imported_from
                            pkg_set.imported_from << imported_from
                            imported_from.imports << pkg_set
                        end
                        next
                    end
                    by_repository_id[repository_id] = [vcs, imported_from]

                    # Make sure the package set has been already checked out to
                    # retrieve the actual name of the package set
                    unless vcs.local?
                        failed = handle_keep_going(keep_going, vcs, failures) do
                            update_remote_package_set(
                                vcs, checkout_only: checkout_only,
                                     only_local: only_local, reset: reset,
                                     retry_count: retry_count
                            )
                        end
                        raw_local_dir = PackageSet.raw_local_dir_of(ws, vcs)

                        # We really can't continue if the VCS was being checked out
                        # and that failed
                        raise failures.last if failed && !File.directory?(raw_local_dir)

                        required_remotes_dirs << raw_local_dir
                    end

                    name = PackageSet.name_of(ws, vcs)

                    required_user_dirs = by_name.collect { |k, v| k }
                    Autoproj.debug "Trying to load package_set: #{name} from definition #{repository_id}"
                    Autoproj.debug "Already loaded package_sets are: #{required_user_dirs}"

                    if (already_loaded = by_name[name])
                        already_loaded_pkg_set, already_loaded_vcs = *already_loaded
                        if already_loaded_vcs != vcs
                            if imported_from
                                Autoproj.warn "redundant auto-import of package set '#{name}' by package set '#{imported_from.name}'"
                                Autoproj.warn "    A package set with the same name has already been imported from"
                                Autoproj.warn "        #{already_loaded_vcs}"
                                Autoproj.warn "    Skipping the following one: "
                                Autoproj.warn "        #{vcs}"
                            else
                                Autoproj.warn "the manifest refers to a package set from #{vcs}, but a package set with the same name (#{name}) has already been imported from #{already_loaded_vcs}, I am skipping this one"
                            end
                        end

                        if imported_from
                            already_loaded_pkg_set.imported_from << imported_from
                            imported_from.imports << already_loaded_pkg_set
                            by_repository_id[repository_id][2] = already_loaded_pkg_set
                        end
                        next
                    end

                    create_remote_set_user_dir(vcs) unless vcs.local?
                    pkg_set = load_package_set(vcs, import_options, imported_from)
                    by_repository_id[repository_id][2] = pkg_set
                    package_sets << pkg_set

                    by_name[pkg_set.name] = [pkg_set, vcs, import_options, imported_from]

                    # Finally, queue the imports
                    queue_auto_imports_if_needed(queue, pkg_set, root_pkg_set)
                end

                required_user_dirs = by_name.collect { |k, v| k }
                cleanup_remotes_dir(package_sets, required_remotes_dirs)
                cleanup_remotes_user_dir(package_sets, required_user_dirs)

                [package_sets, failures]
            end

            # Removes from {remotes_dir} the directories that do not match a package
            # set
            def cleanup_remotes_dir(package_sets = ws.manifest.package_sets, required_remotes_dirs = Array.new)
                # Cleanup the .remotes and remotes_symlinks_dir directories
                Dir.glob(File.join(remotes_dir, "*")).each do |dir|
                    dir = File.expand_path(dir)
                    # Once a package set has been checked out during the process,
                    # keep it -- so that it won't be checked out again
                    if File.directory?(dir) && !required_remotes_dirs.include?(dir)
                        FileUtils.rm_rf dir
                    end
                end
            end

            # Removes from {remotes_user_dir} the directories that do not match a
            # package set
            def cleanup_remotes_user_dir(package_sets = ws.manifest.package_sets, required_user_dirs = Array.new)
                Dir.glob(File.join(remotes_user_dir, "*")).each do |file|
                    file = File.expand_path(file)
                    user_dir = File.basename(file)
                    if File.symlink?(file) && !required_user_dirs.include?(user_dir)
                        FileUtils.rm_f file
                    end
                end
            end

            def inspect
                to_s
            end

            # Sort the package sets by dependency order
            # Package sets that have no dependencies come first,
            # the local package set (by main configuration) last
            def sort_package_sets_by_import_order(package_sets, root_pkg_set)
                c = PackageSetHierarchy.new(package_sets, root_pkg_set)
                c.verify_acyclic
                sorted_pkg_sets = c.flatten

                if sorted_pkg_sets.last != root_pkg_set
                    raise InternalError, "Failed to sort the package sets: the " \
                                         "root package set should be last, but is not #{sorted_pkg_sets.map(&:name)}"
                end

                sorted_pkg_sets
            end

            def load_package_sets(
                only_local: false,
                checkout_only: true,
                keep_going: false,
                reset: false,
                retry_count: nil,
                mainline: nil
            )
                update_configuration(
                    only_local: only_local,
                    checkout_only: checkout_only,
                    keep_going: keep_going,
                    reset: reset,
                    retry_count: retry_count,
                    mainline: mainline
                )
            end

            def report_import_failure(what, reason)
                unless reason.kind_of?(Interrupt)
                    Autoproj.message "import of #{what} failed", :red
                    Autoproj.message reason.to_s, :red
                end
            end

            def handle_keep_going(keep_going, vcs, failures)
                yield
                false
            rescue Interrupt
                raise
            rescue Exception => failure_reason
                if keep_going
                    report_import_failure(vcs, failure_reason)
                    failures << failure_reason
                    true
                else
                    raise
                end
            end

            def update_configuration(
                only_local: false,
                checkout_only: !Autobuild.do_update,
                keep_going: false,
                reset: false,
                retry_count: nil,
                mainline: nil
            )

                if ws.manifest.vcs.needs_import?
                    main_configuration_failure = update_main_configuration(
                        keep_going: keep_going,
                        checkout_only: checkout_only,
                        only_local: only_local,
                        reset: reset,
                        retry_count: retry_count
                    )

                    main_configuration_failure.each do |e|
                        report_import_failure("main configuration", e)
                    end
                else
                    main_configuration_failure = []
                end
                ws.load_main_initrb
                ws.manifest.load(manifest_path)
                root_pkg_set = ws.manifest.main_package_set
                root_pkg_set.load_description_file
                root_pkg_set.explicit = true

                package_sets_failure = update_package_sets(
                    only_local: only_local,
                    checkout_only: checkout_only,
                    keep_going: keep_going,
                    reset: reset,
                    retry_count: retry_count
                )

                load_package_set_information(mainline: mainline)

                if !main_configuration_failure.empty? && !package_sets_failure.empty?
                    raise ImportFailed.new(main_configuration_failure + package_sets_failure)
                elsif !main_configuration_failure.empty?
                    raise ImportFailed.new(main_configuration_failure)
                elsif !package_sets_failure.empty?
                    raise ImportFailed.new(package_sets_failure)
                end
            end

            def load_package_set_information(mainline: nil)
                manifest = ws.manifest
                manifest.each_package_set do |pkg_set|
                    if Gem::Version.new(pkg_set.required_autoproj_version) > Gem::Version.new(Autoproj::VERSION)
                        raise ConfigError.new(pkg_set.source_file), "the #{pkg_set.name} package set requires autoproj v#{pkg_set.required_autoproj_version} but this is v#{Autoproj::VERSION}"
                    end
                end

                # Loads OS repository definitions once and for all
                load_osrepos_from_package_sets

                # Loads OS package definitions once and for all
                load_osdeps_from_package_sets

                # Load the required autobuild definitions
                manifest.each_package_set do |pkg_set|
                    pkg_set.each_autobuild_file do |path|
                        ws.import_autobuild_file pkg_set, path
                    end
                end

                # Now, load the package's importer configurations (from the various
                # source.yml files)
                mainline = manifest.package_set(mainline) if mainline.respond_to?(:to_str)
                manifest.load_importers(mainline: mainline)

                auto_add_packages_from_layout

                manifest.each_autobuild_package do |pkg|
                    Autobuild.each_utility do |uname, _|
                        pkg.utility(uname).enabled =
                            ws.config.utility_enabled_for?(uname, pkg.name)
                    end
                end

                mark_unavailable_osdeps_as_excluded
            end

            # @api private
            #
            # Attempts to find packages mentioned in the layout but that are not
            # defined, and auto-define them if they can be found on disk
            #
            # It only warns about packages that can't be defined that way are on
            def auto_add_packages_from_layout
                manifest = ws.manifest

                # Auto-add packages that are
                #  * present on disk
                #  * listed in the layout part of the manifest
                #  * but have no definition
                explicit = manifest.normalized_layout
                explicit.each do |pkg_or_set, layout_level|
                    next if manifest.find_autobuild_package(pkg_or_set)
                    next if manifest.has_package_set?(pkg_or_set)

                    full_path = File.expand_path(
                        File.join(ws.source_dir, layout_level, pkg_or_set)
                    )
                    next unless File.directory?(full_path)

                    if (handler = auto_add_package(pkg_or_set, full_path))
                        handler_name = handler.gsub(/_package/, "")
                        layout_level_msg = "in #{layout_level} " if layout_level != "/"
                        Autoproj.message "  auto-added #{pkg_or_set} #{layout_level_msg}"\
                                         "using the #{handler_name} package handler"
                    else
                        Autoproj.warn "cannot auto-add #{pkg_or_set}: "\
                                      "unknown package type"
                    end
                end
            end

            # @api private
            #
            # Attempts to auto-add the package checked out at the given path
            #
            # @param [String] full_path
            # @return [String,nil] either the name of the package handler used to
            #   define the package, or nil if no handler could be found
            def auto_add_package(name, full_path)
                manifest = ws.manifest
                handler, _srcdir = Autoproj.package_handler_for(full_path)
                if handler
                    ws.set_as_main_workspace do
                        ws.in_package_set(manifest.main_package_set, manifest.file) do
                            send(handler, name)
                        end
                    end
                    handler
                end
            end

            def mark_unavailable_osdeps_as_excluded
                os_package_resolver = ws.os_package_resolver
                manifest = ws.manifest
                os_package_resolver.all_package_names.each do |osdep_name|
                    # If the osdep can be replaced by source packages, there's
                    # nothing to do really. The exclusions of the source packages
                    # will work as expected
                    if manifest.osdeps_overrides[osdep_name] || manifest.find_autobuild_package(osdep_name)
                        next
                    end

                    case os_package_resolver.availability_of(osdep_name)
                    when OSPackageResolver::UNKNOWN_OS
                        manifest.exclude_package(osdep_name, "the current operating system is unknown to autoproj")
                    when OSPackageResolver::WRONG_OS
                        manifest.exclude_package(osdep_name, "#{osdep_name} is defined, but not for this operating system")
                    when OSPackageResolver::NONEXISTENT
                        manifest.exclude_package(osdep_name, "#{osdep_name} is marked as unavailable for this operating system")
                    end
                end
            end

            # Load OS dependency information contained in our registered package
            # sets into the provided osdep object
            #
            # This is included in {load_package_sets}
            #
            # @return [void]
            def load_osdeps_from_package_sets
                ws.manifest.each_package_set do |pkg_set|
                    pkg_set.each_osdeps_file do |file|
                        file_osdeps = pkg_set.load_osdeps(
                            file, operating_system: ws.operating_system
                        )
                        ws.os_package_resolver.merge(file_osdeps)
                    end
                end
            end

            # Load OS repository information contained in our registered package
            # sets into the provided osrepo object
            #
            # This is included in {load_package_sets}
            #
            # @return [void]
            def load_osrepos_from_package_sets
                ws.manifest.each_package_set do |pkg_set|
                    pkg_set.each_osrepos_file do |file|
                        file_osrepos = pkg_set.load_osrepos(file)
                        ws.os_repository_resolver.merge(file_osrepos)
                    end
                end
            end

            def update_package_sets(only_local: false,
                checkout_only: !Autobuild.do_update,
                keep_going: false,
                reset: false,
                retry_count: nil)
                root_pkg_set = ws.manifest.main_package_set
                package_sets, failures = load_and_update_package_sets(
                    root_pkg_set,
                    only_local: only_local,
                    checkout_only: checkout_only,
                    keep_going: keep_going,
                    reset: reset,
                    retry_count: retry_count
                )
                root_pkg_set.imports.each do |pkg_set|
                    pkg_set.explicit = true
                end

                # sort packages, main package is the last
                package_sets = sort_package_sets_by_import_order(package_sets, root_pkg_set)
                ws.manifest.reset_package_sets
                package_sets.each do |pkg_set|
                    ws.manifest.register_package_set(pkg_set)
                end

                ws.manifest.each_package_set do |pkg_set|
                    ws.load_if_present(pkg_set, pkg_set.local_dir, "init.rb")

                    # Reload the package set description to account for
                    # source files that might have been added through
                    # Autoproj::PackageSet$add_source_file during loading
                    # of the init.rb scripts
                    pkg_set.load_description_file
                end

                failures
            end
        end
    end
end
