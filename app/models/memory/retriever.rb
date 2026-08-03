module Memory
  class Retriever
    CHARS_PER_TOKEN = 4

    # Cosine distance beyond which a nearest-neighbour hit is treated as noise.
    # pgvector returns 0.0 for identical vectors and 2.0 for opposites; related
    # text on text-embedding-3-small typically lands under 0.5. Without a floor,
    # `nearest_neighbors(...).limit(20)` always returns twenty rows no matter how
    # irrelevant they are, and the least-bad of them get injected into the prompt.
    MAX_SEMANTIC_DISTANCE = 0.55

    # Function words carry no retrieval signal but dominate the front of a
    # natural-language question, which is where the old `.first(5)` was looking.
    STOPWORDS = %w[
      the and for was were are you your yours our ours their theirs its
      that this these those with from what when where which who whom whose
      how why did does doing done have has had having been being will would
      can could should shall may might must about into over under again
      any all some more most other such only own same than too very just
      not nor but yet still also then once here there both each few
      say says said tell tells told ask asks asked get gets got
      remind reminds reminded remember remembers remembered know knows knew
      think thinks thought want wants wanted need needs needed
      decide decides decided
    ].to_set.freeze

    def initialize(conversation, budget: 800)
      @conversation = conversation
      @user = conversation.user
      @agent = conversation.agent
      @workspace = conversation.workspace
      @budget = budget
    end

    def call(query:)
      semantic = semantic_search(query)
      keyword = keyword_search(query)

      merged = merge_and_rank(semantic, keyword)
      return nil if merged.empty?

      format(merged)
    end

    # Returns raw MemoryItem records matching the query.
    # Used by the recall virtual tool for richer output formatting.
    # Options:
    #   category: filter by memory category (decision/preference/fact/commitment)
    #   user_ids: search across multiple users (for principal mode)
    #   include_world: also search general/world facts an agent gathered while
    #     researching. Off by default — those are excluded from prompt context,
    #     but an explicit `recall` should still be able to reach them.
    def search(query:, category: nil, user_ids: nil, include_world: false)
      scope_override = MemoryItem.current.unexpired.where(workspace: @workspace)
      scope_override = if user_ids.present?
        scope_override.where(user_id: user_ids)
      else
        scope_override.where(user: @user)
      end

      scope_override = scope_override.readable_by_agent(@agent)
      scope_override = scope_override.about_principal unless include_world
      scope_override = scope_override.where(category: category) if category.present?

      semantic = semantic_search(query, scope: scope_override)
      keyword = keyword_search(query, scope: scope_override)

      merge_and_rank(semantic, keyword)
    end

    private

    # This agent's own memories plus the shared principal core for this user.
    # Sharing is bounded to one (workspace, user) — never across tenants,
    # never across principals — and private categories stay with the agent
    # that formed them.
    def base_scope
      MemoryItem.current
                .about_principal
                .unexpired
                .where(workspace: @workspace, user: @user)
                .readable_by_agent(@agent)
    end

    def semantic_search(query, scope: nil)
      scope ||= base_scope
      client = Rails.configuration.openai_client
      return [] if client.nil?

      response = client.embeddings(
        parameters: { model: "text-embedding-3-small", input: query }
      )

      query_vec = response.dig("data", 0, "embedding")
      return [] unless query_vec

      scope
        .with_embedding
        .nearest_neighbors(:embedding, query_vec, distance: :cosine)
        .limit(20)
        .to_a
        .select { |item| relevant_neighbor?(item) }
    rescue StandardError => e
      Rails.logger.warn("[Memory::Retriever] Semantic search failed: #{e.message}")
      []
    end

    # A hit counts only if it is actually close. `neighbor_distance` is absent
    # when the scope wasn't ordered by distance, in which case we keep the row
    # rather than silently dropping everything.
    def relevant_neighbor?(item)
      distance = item.try(:neighbor_distance)
      distance.nil? || distance <= MAX_SEMANTIC_DISTANCE
    end

    def keyword_search(query, scope: nil)
      words = significant_terms(query)
      return [] if words.empty?

      scope ||= base_scope

      conditions = words.map { "content ILIKE ?" }.join(" OR ")
      values = words.map { |w| "%#{sanitize_like(w)}%" }

      scope
        .where(conditions, *values)
        .order(created_at: :desc)
        .limit(20)
        .to_a
    end

    # Pull the content-bearing words out of a natural-language question.
    # "What did we decide about the Boardwise launch timeline?" must search for
    # boardwise/timeline/launch — not did/decide/about/the, which is what taking
    # the first five long-ish words used to produce.
    def significant_terms(query)
      query.to_s
           .downcase
           .scan(/[[:alnum:]][[:alnum:]'_-]*/)
           .reject { |w| w.length <= 2 || STOPWORDS.include?(w) }
           .uniq
           .sort_by { |w| -w.length } # length as a cheap proxy for rarity
           .first(6)
    end

    def merge_and_rank(semantic, keyword)
      all_items = {}

      # Score semantic results by actual cosine similarity, not by rank. Rank
      # scoring gave the 20th-nearest neighbour a healthy score purely for being
      # in the result set, which made weak matches indistinguishable from strong
      # ones once they were merged with the keyword hits.
      semantic.each do |item|
        distance = item.try(:neighbor_distance)
        similarity = distance ? (1.0 - distance).clamp(0.0, 1.0) : 0.5
        all_items[item.id] = { item: item, score: similarity * 0.6 }
      end

      # Score keyword results: recency-based
      keyword.each_with_index do |item, idx|
        recency_score = (1.0 - (idx.to_f / [keyword.size, 1].max)) * 0.4
        if all_items[item.id]
          all_items[item.id][:score] += recency_score
        else
          all_items[item.id] = { item: item, score: recency_score }
        end
      end

      all_items.values
               .sort_by { |entry| -entry[:score] }
               .map { |entry| entry[:item] }
    end

    def format(items)
      char_limit = @budget * CHARS_PER_TOKEN
      chars_used = 0
      lines = []

      items.each do |item|
        line = "- [#{item.category}] #{item.content} (#{Memory::Retriever.relative_date(item.created_at)})"
        break if chars_used + line.length > char_limit
        chars_used += line.length
        lines << line
      end

      return nil if lines.empty?

      "## Long-Term Memory\n#{lines.join("\n")}"
    end

    # Human-readable relative date. Within 90 days, returns "today",
    # "2d ago", "3w ago"; older dates use absolute YYYY-MM-DD.
    def self.relative_date(time)
      return "unknown date" unless time
      delta = Time.current - time
      return "today" if delta < 24.hours && time.to_date == Time.current.to_date
      days = (delta / 1.day).to_i
      return "#{days}d ago" if days < 14
      weeks = (delta / 7.days).to_i
      return "#{weeks}w ago" if days < 90
      time.strftime("%Y-%m-%d")
    end

    def sanitize_like(string)
      string.gsub(/[%_\\]/) { |c| "\\#{c}" }
    end
  end
end
