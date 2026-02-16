#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "shellwords"

# XDG_CONFIG_HOME and GOG_KEYRING_PASSWORD are injected by the executor
unless ENV["GOG_KEYRING_PASSWORD"]
  $stderr.puts "ERROR: No Google credentials configured for this user"
  exit 1
end

command = ARGV[0].to_s.strip
if command.empty?
  $stderr.puts "Usage: gog-tool.rb <gog-subcommand>"
  exit 1
end

argv = ["/usr/local/bin/gog"] + Shellwords.shellsplit(command) + ["--json", "--no-input"]
stdout, stderr, status = Open3.capture3(*argv)

$stdout.write(stdout)
$stderr.write(stderr)
exit(status.exitstatus || 1)
