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

    def call(input)
      argv = build_argv(input)
      env = build_env
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
      tokens = Shellwords.shellsplit(@tool.command_template)
      tokens.map do |token|
        token.gsub(/\{(\w+)\}/) { input.fetch($1, $1) .to_s }
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

    def execute(env, argv, dir)
      Timeout.timeout(@tool.timeout_seconds) do
        Open3.capture3(env, *argv, chdir: dir)
      end
    end

    def truncate(str)
      return str if str.length <= MAX_OUTPUT_LENGTH
      str[0...MAX_OUTPUT_LENGTH] + "\n... (truncated)"
    end
  end
end
