# backend_sqlite.rb
require "sinatra"
require "json"
require "sequel"
require "securerandom"
require "time"

set :bind, "0.0.0.0"
set :port, 4567

DB_PATH = ENV.fetch("RPG_DB", "rpg.db")
DB = Sequel.sqlite(DB_PATH)

# --- Schema bootstrap ---
DB.create_table?(:characters) do
  String  :id, primary_key: true
  Text    :json, null: false       # full snapshot blob
  String  :updated_at, null: false # ISO8601 string for quick compare
  index   :updated_at
end

DB.create_table?(:events) do
  String  :id, primary_key: true
  String  :character_id, null: false
  Text    :json, null: false
  String  :updated_at, null: false
  index   :character_id
  index   :updated_at
end

CHARACTERS = DB[:characters]
EVENTS     = DB[:events]

helpers do
  def json_body
    request.body.rewind
    s = request.body.read
    s.empty? ? {} : JSON.parse(s)
  rescue
    halt 400, { error: "invalid JSON" }.to_json
  end

  def now_iso
    Time.now.utc.iso8601
  end

  def iso(t)
    t.is_a?(String) ? t : t.to_s
  end

  def parse_iso(s)
    Time.parse(s) rescue Time.at(0)
  end

  def cors!
    headers["Access-Control-Allow-Origin"] = "*"
    headers["Access-Control-Allow-Methods"] = "GET,POST,PUT,OPTIONS"
    headers["Access-Control-Allow-Headers"] = "Content-Type"
  end

  def loot_table
    [
      { key:"iron_sword",    name:"Iron Sword",    effects:{ atk:3 } },
      { key:"wooden_shield", name:"Wooden Shield", effects:{ ac:2 } },
      { key:"mystic_ring",   name:"Mystic Ring",   effects:{ int:2 } },
      { key:"health_potion", name:"Health Potion", effects:{ heal:25 } }
    ]
  end
end

before do
  cors!
  content_type :json
end

options "*" do
  cors!
  200
end

# ---- Characters ----

# Fetch a character snapshot
get "/character/:id" do |id|
  row = CHARACTERS.where(id: id).first
  halt 404, { error: "not found" }.to_json unless row
  row[:json]
end

# Upsert a character snapshot with last write wins by updated_at
put "/character/:id" do |id|
  body = json_body
  incoming_updated = parse_iso(body["updated_at"] || now_iso)

  DB.transaction do
    row = CHARACTERS.where(id: id).for_update.first
    if row.nil?
      CHARACTERS.insert(id: id, json: body.to_json, updated_at: incoming_updated.iso8601)
    else
      current_updated = parse_iso(row[:updated_at])
      if incoming_updated > current_updated
        CHARACTERS.where(id: id).update(json: body.to_json, updated_at: incoming_updated.iso8601)
      end
    end
  end

  { ok: true }.to_json
end

# ---- Events ----

# Accept a batch of events
post "/events/batch" do
  data = json_body
  events = Array(data["events"])
  stored = 0

  DB.transaction do
    events.each do |ev|
      ev_id = ev["id"] || "ev_#{SecureRandom.hex(6)}"
      ev_updated = (ev["updated_at"] || now_iso).to_s
      raw = EVENTS.where(id: ev_id).for_update.first
      if raw.nil?
        EVENTS.insert(id: ev_id,
                      character_id: ev["character_id"] || "unknown",
                      json: ev.to_json,
                      updated_at: ev_updated)
        stored += 1
      else
        # If duplicate id arrives, keep the one with newer updated_at
        if parse_iso(ev_updated) > parse_iso(raw[:updated_at])
          EVENTS.where(id: ev_id).update(json: ev.to_json, updated_at: ev_updated)
          stored += 1
        end
      end
    end
  end

  { ok: true, count: stored }.to_json
end

# ---- Quests ----

# Return a quest title for a character
get "/quests/current_title" do
  char_id = params["character_id"]
  titles = [
    "Goblin Troubles",
    "The Lost Amulet",
    "A Rumor of Riches",
    "Bandits on the Road",
    "Crypt of Forgotten Kings"
  ]
  { title: titles.sample, character_id: char_id }.to_json
end

# Resolve a quest outcome
# Body: { character: { ...snapshot... } }
# Returns: { xp: Integer, loot: [ {key, name, effects} ] }
post "/quests/resolve" do
  payload = json_body
  char = payload["character"] || {}
  xp_gain = rand(18..32)
  loot = []
  loot << loot_table.sample if rand < 0.6

  outcome = { xp: xp_gain, loot: loot }

  # Persist the event
  EVENTS.insert(id: "ev_#{SecureRandom.hex(6)}",
                character_id: char["id"] || "unknown",
                json: {
                  id: "ev_#{SecureRandom.hex(4)}",
                  type: "event",
                  kind: "quest_result",
                  payload: outcome,
                  character_id: char["id"],
                  updated_at: now_iso,
                  version: 1
                }.to_json,
                updated_at: now_iso)

  outcome.to_json
end

# ---- Debug helpers ----

get "/debug/characters" do
  CHARACTERS.order(Sequel.desc(:updated_at)).all.map { |r| JSON.parse(r[:json]) }.to_json
end

get "/debug/events/:id" do |id|
  EVENTS.where(character_id: id).order(:updated_at).all.map { |r| JSON.parse(r[:json]) }.to_json
end
