#!/usr/bin/env ruby
# frozen_string_literal: true

# Bridges Basecamp's single-process OAuth login across two agent turns.
#
# `basecamp auth login` prints an authorization URL and then blocks on stdin
# waiting for the user to paste the callback URL back. Unlike gog, it has no
# --step 1 / --step 2 split, so the two halves cannot be two short-lived
# commands: the process that printed the URL must be the one that receives the
# paste. Solid Queue runs each job in a separate process, so nothing in Ruby
# memory survives between the agent's "start" and "complete" calls.
#
# This script is spawned detached and outlives both. It:
#   1. starts the login, streaming its output to auth.log
#   2. polls for auth.callback, written later by Basecamp::Authenticator
#   3. feeds that callback URL to the login process on stdin
#   4. records the outcome in auth.status, then exits
#
# Usage: auth_bridge.rb <config_home> <basecamp_bin>

require "open3"
require "fileutils"

config_home = ARGV[0].to_s
bin = ARGV[1].to_s
abort "usage: auth_bridge.rb <config_home> <basecamp_bin>" if config_home.empty? || bin.empty?

FileUtils.mkdir_p(config_home)
log_path      = File.join(config_home, "auth.log")
callback_path = File.join(config_home, "auth.callback")
status_path   = File.join(config_home, "auth.status")

# A stale callback from an earlier attempt would be consumed instantly by this
# run and fail against a fresh state parameter.
FileUtils.rm_f([log_path, callback_path, status_path])

TIMEOUT = 900 # 15 minutes for a human to approve in a browser

def finish(status_path, state, detail)
  File.write(status_path, "#{state}\n#{detail}")
end

env = {
  "XDG_CONFIG_HOME" => config_home,
  "BASECAMP_NONINTERACTIVE" => "1"
}

begin
  Open3.popen2e(env, bin, "auth", "login", "--device-code", "--no-browser") do |stdin, out, wait_thr|
    log = File.open(log_path, "a")
    log.sync = true

    # The CLI's output is consumed on a thread so the URL lands in auth.log
    # while the child is still blocked waiting for the paste.
    reader = Thread.new do
      out.each_char { |c| log.write(c) }
    rescue IOError
      nil
    end

    deadline = Time.now + TIMEOUT
    delivered = false

    until delivered || Time.now > deadline || !wait_thr.alive?
      if File.exist?(callback_path)
        callback = File.read(callback_path).strip
        unless callback.empty?
          begin
            stdin.puts(callback)
            stdin.flush
          rescue Errno::EPIPE
            # Child already exited; the log and exit status tell the story.
          end
          delivered = true
        end
      end
      sleep 0.5 unless delivered
    end

    unless delivered
      finish(status_path, "timeout", "No callback URL was provided within #{TIMEOUT} seconds.")
      begin
        Process.kill("TERM", wait_thr.pid)
      rescue Errno::ESRCH
        nil
      end
      reader.join(2)
      log.close
      exit 1
    end

    status = wait_thr.value
    reader.join(5)
    log.close

    if status.success?
      finish(status_path, "ok", "Authenticated.")
    else
      tail = File.read(log_path).to_s.lines.last(5).join.strip
      finish(status_path, "failed", tail.empty? ? "Login exited #{status.exitstatus}." : tail)
    end
    exit(status.exitstatus || 1)
  end
rescue Errno::ENOENT
  finish(status_path, "failed", "The basecamp CLI was not found at #{bin}.")
  exit 1
rescue => e
  finish(status_path, "failed", "#{e.class}: #{e.message}")
  exit 1
ensure
  FileUtils.rm_f(callback_path)
end
