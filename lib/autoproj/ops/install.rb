require 'optparse'
require 'fileutils'
require 'yaml'

module Autoproj
    module Ops
        # This class contains the functionality necessary to install autoproj in a
        # clean root
        #
        # It can be required standalone (i.e. does not depend on anything else than
        # ruby and the ruby standard library)
        class Install
            # The directory in which to install autoproj
            attr_reader :root_dir
            # Content of the Gemfile generated to install autoproj itself
            attr_accessor :gemfile

            def initialize(root_dir)
                @root_dir = root_dir
                @gemfile  = default_gemfile_contents
                @private_bundler  = false
                @private_autoproj = false
                @private_gems     = false
            end

            def dot_autoproj; File.join(root_dir, '.autoproj') end
            def bin_dir; File.join(dot_autoproj, 'bin') end
            def bundler_install_dir; File.join(dot_autoproj, 'bundler') end
            def autoproj_install_dir; File.join(dot_autoproj, 'autoproj') end
            # The path to the gemfile used to install autoproj
            def autoproj_gemfile_path; File.join(autoproj_install_dir, 'Gemfile') end
            def autoproj_config_path; File.join(dot_autoproj, 'config.yml') end

            # Whether bundler should be installed locally in {#dot_autoproj}
            def private_bundler?; @private_bundler end
            # Whether autoproj should be installed locally in {#dot_autoproj}
            def private_autoproj?; @private_autoproj end
            # Whether bundler should be installed locally in the workspace
            # prefix directory
            def private_gems?; @private_gems end

            def guess_gem_program
                ruby_bin = RbConfig::CONFIG['RUBY_INSTALL_NAME']
                ruby_bindir = RbConfig::CONFIG['bindir']

                candidates = ['gem']
                if ruby_bin =~ /^ruby(.+)$/
                    candidates << "gem#{$1}" 
                end

                candidates.each do |gem_name|
                    if File.file?(gem_full_path = File.join(ruby_bindir, gem_name))
                        return gem_full_path
                    end
                end
                raise ArgumentError, "cannot find a gem program (tried #{candidates.sort.join(", ")} in #{ruby_bindir})"
            end

            # The content of the default {#gemfile}
            #
            # @param [String] autoproj_version a constraint on the autoproj version
            #   that should be used
            # @return [String]
            def default_gemfile_contents(autoproj_version = ">= 2.0.0.a")
                ["source \"https://rubygems.org\"",
                 "gem \"autoproj\", \"#{autoproj_version}\"",
                 "gem \"utilrb\", \">= 3.0.0.a\""].join("\n")
            end

            # Parse the provided command line options and returns the non-options
            def parse_options(args = ARGV)
                options = OptionParser.new do |opt|
                    opt.on '--private-bundler', 'install bundler locally in the workspace' do
                        @private_bundler = true
                    end
                    opt.on '--private-autoproj', 'install autoproj locally in the workspace' do
                        @private_autoproj = true
                    end
                    opt.on '--private-gems', 'install gems locally in the prefix directory' do
                        @private_gems = true
                    end
                    opt.on '--private', 'whether bundler, autoproj and the workspace gems should be installed locally in the workspace' do
                        @private_bundler = true
                        @private_autoproj = true
                        @private_gems = true
                    end
                    opt.on '--version=VERSION_CONSTRAINT', String, 'use the provided string as a version constraint for autoproj' do |version|
                        @gemfile = default_gemfile_contents(version)
                    end
                    opt.on '--gemfile=PATH', String, 'use the given Gemfile to install autoproj instead of the default' do |path|
                        @gemfile = File.read(path)
                    end
                end
                options.parse(ARGV)
            end

            def install_bundler
                gem_program  = guess_gem_program
                puts "Detected 'gem' to be #{gem_program}"

                result = system(
                    Hash['GEM_PATH' => nil,
                         'GEM_HOME' => bundler_install_dir],
                    gem_program, 'install', '--no-document', '--no-user-install', '--no-format-executable',
                        "--bindir=#{File.join(bundler_install_dir, 'bin')}", 'bundler')

                if !result
                    STDERR.puts "FATAL: failed to install bundler in #{dot_autoproj}"
                    exit 1
                end
                File.join(bin_dir, 'bundler')
            end

            def save_env_sh
                env = Autobuild::Environment.new
                path = []
                if private_bundler?
                    env.push_path 'PATH', File.join(bundler_install_dir, 'bin')
                    env.push_path 'GEM_PATH', bundler_install_dir
                end
                env.push_path 'PATH', File.join(autoproj_install_dir, 'bin')
                env.inherit 'PATH'
                if private_autoproj?
                    env.push_path 'GEM_PATH', autoproj_install_dir
                end

                # Generate environment files right now, we can at least use bundler
                File.open(File.join(dot_autoproj, 'env.sh'), 'w') do |io|
                    env.export_env_sh(io)
                end

                File.open(File.join(root_dir, 'env.sh'), 'w') do |io|
                    io.write <<-EOSHELL
source "#{File.join(dot_autoproj, 'env.sh')}"
export AUTOPROJ_CURRENT_ROOT=#{root_dir}
                    EOSHELL
                end
            end

            def save_gemfile
                FileUtils.mkdir_p File.dirname(autoproj_gemfile_path)
                File.open(autoproj_gemfile_path, 'w') do |io|
                    io.write gemfile
                end
            end
            
            def install_autoproj(bundler)
                # Force bundler to update. If the user does not want this, let him specify a
                # Gemfile with tighter version constraints
                lockfile = File.join(File.dirname(autoproj_gemfile_path), 'Gemfile.lock')
                if File.exist?(lockfile)
                    FileUtils.rm lockfile
                end

                env = Hash['BUNDLE_GEMFILE' => nil, 'RUBYLIB' => nil]
                if (gem_home = ENV['GEM_HOME']) && Workspace.in_autoproj_project?(gem_home)
                    env['GEM_HOME'] = nil
                end
                opts = Array.new

                if private_autoproj?
                    env = env.merge(
                        'GEM_PATH' => bundler_install_dir,
                        'GEM_HOME' => nil)
                    opts << "--clean" << "--path=#{autoproj_install_dir}"
                end

                result = system(env,
                    bundler, 'install',
                        "--gemfile=#{autoproj_gemfile_path}",
                        "--binstubs=#{File.join(autoproj_install_dir, 'bin')}",
                        *opts)
                if !result
                    STDERR.puts "FATAL: failed to install autoproj in #{dot_autoproj}"
                    exit 1
                end
            end

            def update_configuration
                if File.exist?(autoproj_config_path)
                    config = YAML.load(File.read(autoproj_config_path)) || Hash.new
                else
                    config = Hash.new
                end
                config['private_bundler']  = private_bundler?
                config['private_autoproj'] = private_autoproj?
                config['private_gems']     = private_gems?
                File.open(autoproj_config_path, 'w') do |io|
                    YAML.dump(config, io)
                end
            end

            def install
                if private_bundler?
                    puts "Installing bundler in #{bundler_install_dir}"
                    bundler = install_bundler
                end
                save_gemfile
                puts "Installing autoproj in #{dot_autoproj}"
                install_autoproj(bundler || 'bundler')
            end

            # Actually perform the install
            def run
                install
                ENV['BUNDLE_GEMFILE'] = autoproj_gemfile_path
                require 'bundler'
                Bundler.setup
                require 'autobuild'
                save_env_sh
                update_configuration
            end
        end
    end
end
