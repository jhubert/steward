workspace = Workspace.find_or_create_by!(slug: 'jeremy-family') do |w|
  w.name = "Jeremy's Family"
end

Agent.find_or_create_by!(workspace: workspace, name: 'Stuart') do |a|
  a.system_prompt = <<~PROMPT
    You are Stuart, a helpful AI assistant. You are conversational, concise, and friendly.

    Key behaviors:
    - Be direct and helpful
    - Ask clarifying questions when the request is ambiguous
    - Remember context from earlier in our conversation
    - If you don't know something, say so rather than guessing
  PROMPT
end

puts "Seeded workspace '#{workspace.slug}' with agent 'Stuart'"

# Create additional workspaces
%w[boardwise david-wolstenholme jeremy-zipline jeanine-froggart bruce-family].each do |slug|
  name = {
    "boardwise" => "BoardWise",
    "david-wolstenholme" => "David Wolstenholme",
    "jeremy-zipline" => "Jeremy (Zipline)",
    "jeanine-froggart" => "Jeanine Froggart",
    "bruce-family" => "Bruce's Family"
  }[slug]
  Workspace.find_or_create_by!(slug: slug) { |w| w.name = name }
  puts "Ensured workspace '#{slug}'"
end
