# This file will be responsible for generating new Point Crawl quests.
require_relative 'point_crawl'

module PointCrawl
  class QuestGenerator
    def self.generate(quest_id)
      quest = Quest.new(quest_id)

      # --- Config ---
      num_nodes = rand(20..30)
      extra_connections = num_nodes / 2

      # --- Node Creation ---
      nodes = (0...num_nodes).map do |i|
        PointOfInterest.new("node_#{i}", "Location #{i}", "A mysterious place.", type: :generic)
      end
      nodes.each { |n| quest.add_node(n) }

      # --- Graph Generation ---
      # 1. Create a main path to guarantee connectivity from start to end
      main_path = nodes.shuffle
      quest.start_node_id = main_path.first.id
      quest.end_node_id = main_path.last.id

      main_path.each_cons(2) do |a, b|
        a.add_connection(b.id)
        b.add_connection(a.id) # Make connections bidirectional for now
      end

      # 2. Add extra connections to create a graph
      extra_connections.times do
        a = nodes.sample
        b = nodes.sample
        next if a.id == b.id || a.connections.include?(b.id)
        a.add_connection(b.id)
        b.add_connection(a.id)
      end

      # --- Encounter Population ---
      # For now, we'll use some placeholder encounters.
      # This could be loaded from YAML/JSON files in the future.
      location_encounters = [
        Encounter.new(description: "You find a crumbling statue.", rewards: [Reward.new(:xp, 10)]),
        Encounter.new(description: "A strange beast scurries away into the undergrowth.", rewards: [Reward.new(:xp, 5)]),
        Encounter.new(description: "You discover a hidden chest!", rewards: [Reward.new(:xp, 25), Reward.new(:loot, { key: "gold_coin", name: "Gold Coin" })])
      ]
      travel_encounters = [
        Encounter.new(description: "You are ambushed by bandits!", rewards: [Reward.new(:xp, 50), Reward.new(:loot, { key: "dagger", name: "Dagger" })]),
        Encounter.new(description: "A friendly merchant crosses your path.", rewards: []),
        Encounter.new(description: "The journey is quiet and uneventful.", rewards: [])
      ]

      nodes.each do |node|
        # Each location gets 1-2 encounters
        (1..rand(1..2)).each do
          node.add_encounter(location_encounters.sample)
        end
      end

      travel_encounters.each do |encounter|
        quest.add_travel_encounter(encounter)
      end

      quest
    end
  end
end
