# This file will be responsible for generating new Point Crawl quests.
require_relative 'point_crawl'

module PointCrawl
  class QuestGenerator
    def self.generate(quest_id:, locations:, enemies:, titles:)
      quest_title = titles.sample ? titles.sample["title"] : "A Grand Adventure"
      quest = Quest.new(quest_id, quest_title)

      # --- Config ---
      num_nodes = [locations.length, rand(20..30)].min
      return nil if num_nodes == 0 # Cannot generate a quest without locations
      extra_connections = num_nodes / 2

      # --- Node Creation ---
      # Take a sample of the available locations
      node_templates = locations.sample(num_nodes)
      nodes = node_templates.map.with_index do |loc_template, i|
        PointOfInterest.new(
          "node_#{i}",
          loc_template["name"],
          loc_template["description"],
          type: loc_template["type"].to_sym
        )
      end
      nodes.each { |n| quest.add_node(n) }

      # --- Graph Generation ---
      main_path = nodes.shuffle
      quest.start_node_id = main_path.first.id
      quest.end_node_id = main_path.last.id

      main_path.each_cons(2) do |a, b|
        a.add_connection(b.id)
        b.add_connection(a.id)
      end

      extra_connections.times do
        a = nodes.sample
        b = nodes.sample
        next if a.id == b.id || a.connections.include?(b.id)
        a.add_connection(b.id)
        b.add_connection(a.id)
      end

      # --- Encounter Population ---
      # Populate with enemies, or have some peaceful locations
      nodes.each do |node|
        # 70% chance of an encounter
        if rand < 0.7 && enemies.any?
          enemy = enemies.sample
          node.add_encounter(Encounter.new(
            description: "You are confronted by a #{enemy["name"]}!",
            enemy_id: enemy["id"]
          ))
        else
          # Add a peaceful encounter description
          node.add_encounter(Encounter.new(description: "The area is quiet. You find a moment to rest."))
        end
      end

      # Add some travel encounters
      if enemies.any?
        3.times do
          enemy = enemies.sample
          quest.add_travel_encounter(Encounter.new(
            description: "On the road, you are ambushed by a #{enemy["name"]}!",
            enemy_id: enemy["id"]
          ))
        end
      end

      quest
    end
  end
end
