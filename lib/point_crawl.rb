# This file contains the data structures for the Point Crawl quest system.
require 'securerandom'

module PointCrawl
  # Represents a single reward from an encounter.
  class Reward
    attr_reader :type, :value

    # @param type [Symbol] :xp or :loot
    # @param value [Object] Integer for XP, or a hash for loot.
    def initialize(type, value)
      @type = type
      @value = value
    end

    def to_h
      { type: @type, value: @value }
    end
  end

  # Represents a single encounter that can happen at a PointOfInterest.
  class Encounter
    attr_reader :id, :description, :rewards

    def initialize(id: SecureRandom.hex(4), description:, rewards: [])
      @id = id
      @description = description
      @rewards = rewards
    end

    def to_h
      { id: @id, description: @description, rewards: @rewards.map(&:to_h) }
    end
  end

  # Represents a location in the quest.
  class PointOfInterest
    attr_accessor :id, :name, :description, :type, :connections, :encounters

    # @param id [String]
    # @param name [String]
    # @param description [String]
    # @param type [Symbol] e.g. :town, :dungeon, :ruin
    def initialize(id, name, description, type: :generic)
      @id = id
      @name = name
      @description = description
      @type = type
      @connections = [] # Array of node IDs this point connects to.
      @encounters = []  # Array of Encounter objects specific to this point.
    end

    def add_connection(node_id)
      @connections << node_id unless @connections.include?(node_id)
    end

    def add_encounter(encounter)
      @encounters << encounter
    end

    def to_h
      {
        id: @id,
        name: @name,
        description: @description,
        type: @type,
        connections: @connections,
        encounters: @encounters.map(&:to_h)
      }
    end
  end

  # Represents the entire quest graph and state.
  class Quest
    attr_accessor :id, :name, :nodes, :start_node_id, :end_node_id, :travel_encounters

    def initialize(id, name = "A Grand Adventure")
      @id = id
      @name = name
      @nodes = {}
      @travel_encounters = [] # Encounters that can happen when moving between any two nodes.
    end

    def add_node(node)
      @nodes[node.id] = node
    end

    def get_node(id)
      @nodes[id]
    end

    def add_travel_encounter(encounter)
      @travel_encounters << encounter
    end

    # Serialize the entire quest to a hash for storage (e.g., in JSON).
    def to_h
      {
        id: @id,
        name: @name,
        start_node_id: @start_node_id,
        end_node_id: @end_node_id,
        nodes: @nodes.transform_values(&:to_h),
        travel_encounters: @travel_encounters.map(&:to_h)
      }
    end

    # Deserialize a hash back into a Quest object.
    def self.from_h(hash)
      quest = new(hash['id'], hash['name'])
      quest.start_node_id = hash['start_node_id']
      quest.end_node_id = hash['end_node_id']

      hash['nodes'].each do |node_id, node_hash|
        poi = PointOfInterest.new(node_hash['id'], node_hash['name'], node_hash['description'], type: node_hash['type'].to_sym)
        node_hash['connections'].each { |conn_id| poi.add_connection(conn_id) }
        node_hash['encounters'].each do |enc_hash|
          rewards = enc_hash['rewards'].map { |r| Reward.new(r['type'].to_sym, r['value']) }
          poi.add_encounter(Encounter.new(id: enc_hash['id'], description: enc_hash['description'], rewards: rewards))
        end
        quest.add_node(poi)
      end

      hash['travel_encounters'].each do |enc_hash|
        rewards = enc_hash['rewards'].map { |r| Reward.new(r['type'].to_sym, r['value']) }
        quest.add_travel_encounter(Encounter.new(id: enc_hash['id'], description: enc_hash['description'], rewards: rewards))
      end

      quest
    end
  end
end
