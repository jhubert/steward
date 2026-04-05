require 'open3'
require 'shellwords'
require 'timeout'

module Tools
  class Executor
    Result = Data.define(:stdout, :stderr, :exit_code, :timed_out)

    MAX_OUTPUT_LENGTH = 50_000

    def initialize(agent_tool:)
      @tool = agent_tool
    end

    def call(input, extra_env: {})
      argv = build_argv(input)
      env = build_env.merge(extra_env)
      dir = resolve_working_directory

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = execute(env, argv, dir)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

      Result.new(
        stdout: truncate(stdout),
        stderr: truncate(stderr),
        exit_code: status.exitstatus,
        timed_out: false
      )
    rescue Timeout::Error
      duration_ms = (@tool.timeout_seconds * 1000)
      Result.new(
        stdout: truncate(stdout || ""),
        stderr: "Execution timed out after #{@tool.timeout_seconds} seconds",
        exit_code: nil,
        timed_out: true
      )
    end


    def build_argv(input)
      normalized = input.transform_keys(&:to_s)
      tokens = Shellwords.shellsplit(@tool.command_template)
      tokens.map do |token|
        token.gsub(/\{(\w+)\}/) { normalized.fetch($1, $1).to_s }
      end
    end

    def build_env
      @tool.credentials.transform_values(&:to_s)
    end

    def resolve_working_directory
      if @tool.working_directory.present?
        @tool.working_directory
      else
        Rails.root.to_s
      end
    end

    private

    # Uses popen3 + IO.select for timeout-safe execution.
    # Timeout.timeout + Open3.capture3 leaves background reader threads alive
    # after a timeout fires, causing "stream closed in another thread (IOError)"
    # noise in logs. This approach reads output in the main thread and kills
    # the process explicitly on timeout.
    def execute(env, argv, dir)
      stdout_str = String.new
      stderr_str = String.new
      timed_out  = false

      Open3.popen3(env, *argv, chdir: dir) do |stdin, stdout, stderr, wait_thr|
        stdin.close

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @tool.timeout_seconds
        readers  = [ stdout, stderr ]

        until readers.empty?
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            timed_out = true
            break
          end

          ready, = IO.select(readers, nil, nil, [ remaining, 0.05 ].min)
          next unless ready

          ready.each do |io|
            begin
              chunk = io.read_nonblock(65_536)
              (io == stdout ? stdout_str : stderr_str) << chunk
            rescue IO::EAGAINWaitReadable
              # not ready yet
            rescue EOFError
              readers.delete(io)
            end
          end
        end

        if timed_out
          begin
            Process.kill("TERM", wait_thr.pid)
            wait_thr.join(5) || (Process.kill("KILL", wait_thr.pid) rescue nil; wait_thr.join)
          rescue Errno::ESRCH
            # process already exited
          end
          raise Timeout::Error
        end

        [ stdout_str, stderr_str, wait_thr.value ]
      end
    end

    def truncate(str)
      return str if str.length <= MAX_OUTPUT_LENGTH
      str[0...MAX_OUTPUT_LENGTH] + "\n... (truncated)"
    end
  end
end
