namespace :delivery_gate do
  desc "Review what the delivery gate would have held. Usage: delivery_gate:review[AgentName,days]"
  task :review, [:agent_name, :days] => :environment do |_t, args|
    agent = Agent.unscoped.find_by(name: args[:agent_name] || "Jennifer Lawson")
    abort "Agent not found" unless agent
    Current.workspace = agent.workspace
    days = (args[:days] || 7).to_i

    scope = DeliveryDecision.unscoped.where(agent: agent)
                            .where("delivery_decisions.created_at > ?", days.days.ago)
    total = scope.count

    puts "#{agent.name} — delivery gate, last #{days} days (mode: #{Decisions::DeliveryGate.mode_for(agent)})"
    puts "=" * 92

    if total.zero?
      puts "No decisions recorded yet. The gate only evaluates agent-triggered background"
      puts "turns, so this fills up as scheduled tasks fire."
      next
    end

    held = scope.where(would_deliver: false)
    puts "Decisions: #{total}   would hold: #{held.count} (#{(100.0 * held.count / total).round}%)   " \
         "actually held: #{scope.where(delivered: false).count}"
    puts

    puts "By reason:"
    scope.group(:reason).count.sort_by { |_, c| -c }.each do |reason, c|
      puts format("  %-40s %d", reason.to_s.truncate(40), c)
    end

    tokens = scope.sum(:input_tokens).to_i
    puts
    puts format("Cost: $%.5f over %d decisions (mean %dms, %d input tokens each)",
                tokens * 0.042 / 1e6, total,
                scope.average(:duration_ms).to_f, tokens / [total, 1].max)

    puts
    puts "WOULD HAVE BEEN HELD — read these and decide whether silence was right:"
    puts "-" * 92
    held.includes(:message).order(created_at: :desc).limit(40).each do |d|
      puts format("  %s  [%s]", d.created_at.strftime("%b %d %H:%M"), d.reason.truncate(34))
      puts format("      %s", d.message&.content.to_s.gsub(/\s+/, " ").truncate(150))
      sig = (d.signals || {}).map { |k, v| "#{k.to_s.split('_').first}=#{v.is_a?(Numeric) ? format('%.2f', v) : v}" }
      puts format("      %s", sig.join(" "))
      puts
    end

    puts "CLOSEST SENDS — weakest cases that would still go through:"
    puts "-" * 92
    scope.where(would_deliver: true, reason: "default send")
         .includes(:message).order(created_at: :desc).limit(10)
         .sort_by { |d| d.signals.to_h["needs_recipient"].to_f }.first(5).each do |d|
      puts format("  needs=%.2f  %s",
                  d.signals.to_h["needs_recipient"].to_f,
                  d.message&.content.to_s.gsub(/\s+/, " ").truncate(120))
    end
  end

  desc "Set gate mode. Usage: delivery_gate:mode[AgentName,off|shadow|enforcing]"
  task :mode, [:agent_name, :mode] => :environment do |_t, args|
    agent = Agent.unscoped.find_by(name: args[:agent_name])
    abort "Agent not found" unless agent
    mode = args[:mode].to_s
    abort "Mode must be one of #{Decisions::DeliveryGate::MODES.join(', ')}" unless Decisions::DeliveryGate::MODES.include?(mode)

    Current.workspace = agent.workspace
    agent.update!(settings: agent.settings.merge("delivery_gate" => mode))
    puts "#{agent.name}: delivery_gate=#{mode}"
    puts "Restart steward and steward-jobs for the tool definition change to take effect." if mode != "off"
  end
end
