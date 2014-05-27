require "enumerator"
require 'autobuild'
require 'autoproj/base'
require 'autoproj/version'
require 'autoproj/environment'
require 'autoproj/variable_expansion'
require 'autoproj/vcs_definition'
require 'autoproj/package_set'
require 'autoproj/package_definition'
require 'autoproj/package_selection'
require 'autoproj/metapackage'
require 'autoproj/manifest'
require 'autoproj/package_manifest'
require 'autoproj/installation_manifest'
require 'autoproj/osdeps'
require 'autoproj/system'
require 'autoproj/options'
require 'autoproj/cmdline'
require 'autoproj/query'
require 'logger'
require 'utilrb/logger'
require 'json'

module Autoproj
    class << self
        attr_reader :logger
    end
    @logger = Logger.new(STDOUT)
    logger.level = Logger::WARN
    logger.formatter = lambda { |severity, time, progname, msg| "#{severity}: #{msg}\n" }
    extend Logger::Forward
end

