#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "shellwords"

command = ARGV[0].to_s.strip
if command.empty?
  $stderr.puts "Usage: run.rb <gh-subcommand>"
  exit 1
end

argv = ["/usr/bin/gh"] + Shellwords.shellsplit(command)
stdout, stderr, status = Open3.capture3(*argv)

$stdout.write(stdout)
$stderr.write(stderr)
exit(status.exitstatus || 1)
