require "digest"
require "json"
require "net/http"
require "time"
require "uri"

SITE_KEY = "a62ninj09x"

def fetch_json(url, headers = {})
  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  headers.each { |key, value| request[key] = value }
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |http| http.request(request) }
  raise "HTTP #{response.code} for #{url}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end

def coordinate_key(point)
  format("%.3f,%.3f", point.fetch("lat").to_f, point.fetch("lon").to_f)
end

def source_key(point)
  [coordinate_key(point), point["city"], point["country_code"]].map(&:to_s).join("|")
end

def parse_time(value, fallback)
  value ? Time.parse(value).utc : fallback
rescue ArgumentError
  fallback
end

def load_previous(path)
  return {} unless File.exist?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError
  {}
end

def region_cache(data)
  Array(data["visitors"]).each_with_object({}) do |visitor, cache|
    next unless visitor["lat"] && visitor["lon"]
    cache[coordinate_key(visitor)] = {
      "city" => visitor["city"],
      "region" => visitor["region"],
      "country" => visitor["country"]
    }
  end
end

def reverse_geocode(point)
  params = URI.encode_www_form(
    format: "jsonv2",
    lat: point.fetch("lat"),
    lon: point.fetch("lon"),
    zoom: 10,
    addressdetails: 1
  )
  data = fetch_json(
    "https://nominatim.openstreetmap.org/reverse?#{params}",
    "User-Agent" => "Hik289.github.io visitor map (xinyuan.song@emory.edu)",
    "Accept-Language" => "en"
  )
  address = data.fetch("address", {})
  {
    "city" => point["city"] || address["city"] || address["town"] || address["village"] || address["municipality"],
    "region" => address["state"] || address["province"] || address["region"] || address["state_district"],
    "country" => address["country"]
  }
rescue StandardError
  { "city" => point["city"], "region" => nil, "country" => nil }
end

def location_for(point, cache)
  key = coordinate_key(point)
  location = cache[key] || {}
  if location["region"].nil? || location["country"].nil?
    geocoded = reverse_geocode(point)
    location = location.merge(geocoded) { |_field, existing, replacement| existing || replacement }
    cache[key] = location
    sleep 1.1
  end
  location
end

def event_id(key, timestamp, nonce)
  Digest::SHA256.hexdigest([key, timestamp.iso8601(6), nonce].join("|"))[0, 20]
end

def build_event(point, timestamp, nonce, cache, source)
  location = location_for(point, cache)
  {
    "id" => event_id(source_key(point), timestamp, nonce),
    "source_key" => source_key(point),
    "source" => source,
    "city" => point["city"] || location["city"],
    "region" => location["region"],
    "country" => location["country"],
    "country_code" => point["country_code"],
    "lat" => point.fetch("lat").to_f.round(3),
    "lon" => point.fetch("lon").to_f.round(3),
    "status" => "seen",
    "visits" => 1,
    "live_visits" => 0,
    "first_seen" => timestamp.iso8601,
    "last_seen" => timestamp.iso8601
  }
end

def migrate_events(data, fallback)
  visitors = Array(data["visitors"])
  return visitors.map(&:dup) if data["schema_version"].to_i >= 2

  visitors.flat_map do |visitor|
    count = [visitor["visits"].to_i, 1].max
    timestamp = parse_time(visitor["last_seen"], fallback)
    count.times.map do |index|
      copy = visitor.dup
      copy["id"] = event_id(source_key(visitor), timestamp, "legacy-#{index}")
      copy["source_key"] = source_key(visitor)
      copy["source"] = "legacy"
      copy["status"] = "seen"
      copy["visits"] = 1
      copy["live_visits"] = 0
      copy
    end
  end
end

def recent_additions(points, previous_keys)
  return [] if previous_keys.empty?
  current_keys = points.map { |point| source_key(point) }
  matches = []
  0.upto(current_keys.length) do |offset|
    overlap = [current_keys.length - offset, previous_keys.length].min
    next unless overlap.positive?
    next unless current_keys.slice(offset, overlap) == previous_keys.slice(0, overlap)
    matches << [overlap, offset]
  end
  return points if matches.empty?
  _overlap, offset = matches.max_by { |overlap, candidate_offset| [overlap, -candidate_offset] }
  points.first(offset)
end

now = Time.now.utc
previous_path = ENV.fetch("PREVIOUS_VISITOR_DATA", "/tmp/visitor-locations-previous.json")
previous_data = load_previous(previous_path)
previous_updated_at = parse_time(previous_data["updated_at"], now)
location_cache = region_cache(previous_data)
events = migrate_events(previous_data, previous_updated_at)
events.each do |event|
  event["status"] = "seen"
  event["live_visits"] = 0
end

headers = { "X-Requested-With" => "XMLHttpRequest", "User-Agent" => "Hik289.github.io visitor map updater" }
base = "https://whos.amung.us/stats/data/?k=#{SITE_KEY}&v=free"
live_data = fetch_json("#{base}&pins=new", headers)
recent_data = fetch_json("#{base}&pins=old", headers)
live_points = Array(live_data["pins"])
recent_points = Array(recent_data["pins"])
current_recent_keys = recent_points.map { |point| source_key(point) }
previous_recent_keys = Array(previous_data["source_recent_keys"])

new_recent_points = recent_additions(recent_points, previous_recent_keys)
if previous_recent_keys.empty? && previous_data["schema_version"].to_i < 2
  previous_counts = Hash.new(0)
  Array(previous_data["visitors"]).each do |visitor|
    previous_counts[source_key(visitor)] += [visitor["visits"].to_i, 1].max
  end
  current_counts = Hash.new(0)
  recent_points.each { |point| current_counts[source_key(point)] += 1 }
  new_recent_points = recent_points.each_with_object([]) do |point, additions|
    key = source_key(point)
    next unless current_counts[key] > previous_counts[key]
    additions << point
    previous_counts[key] += 1
  end
end

previous_last_hour = previous_data["source_last_hour"]
last_hour_delta = previous_last_hour.nil? ? 0 : recent_data["last_hour"].to_i - previous_last_hour.to_i
if new_recent_points.empty? && last_hour_delta.positive? && recent_points.any?
  [last_hour_delta, recent_points.length].min.times do |index|
    new_recent_points << recent_points[index % recent_points.length]
  end
end

new_recent_points.each_with_index do |point, index|
  key = source_key(point)
  existing_live = events.reverse.find do |event|
    event["source"] == "live" && event["source_key"] == key && now - parse_time(event["last_seen"], now) <= 7200
  end
  if existing_live
    existing_live["source"] = "recent"
    existing_live["last_seen"] = now.iso8601
  else
    events << build_event(point, now, "recent-#{index}", location_cache, "recent")
  end
end

matched_live_ids = {}
live_points.each_with_index do |point, index|
  observed_at = point["time"] ? now - point["time"].to_i : now
  key = source_key(point)
  match = events.reverse.find do |event|
    next false if matched_live_ids[event["id"]]
    next false unless event["source_key"] == key
    (observed_at - parse_time(event["last_seen"], observed_at)).abs <= 600
  end
  unless match
    match = build_event(point, observed_at, "live-#{index}", location_cache, "live")
    events << match
  end
  match["status"] = "live"
  match["live_visits"] = 1
  match["last_seen"] = [parse_time(match["last_seen"], observed_at), observed_at].max.iso8601
  matched_live_ids[match["id"]] = true
end

events = events.map do |event|
  last_seen = parse_time(event["last_seen"], previous_updated_at)
  event.merge(
    "status" => event["status"] == "live" ? "live" : "seen",
    "visits" => 1,
    "live_visits" => event["status"] == "live" ? 1 : 0,
    "first_seen" => parse_time(event["first_seen"], last_seen).iso8601,
    "last_seen" => last_seen.iso8601,
    "age_s" => [(now - last_seen).to_i, 0].max
  )
end.sort_by { |event| [event["status"] == "live" ? 1 : 0, event["last_seen"]] }.reverse

output = {
  "schema_version" => 2,
  "updated_at" => now.iso8601,
  "online_now" => live_data["total_count"].to_i,
  "locations" => events.map { |event| coordinate_key(event) }.uniq.length,
  "visits_total" => events.length,
  "source_last_hour" => recent_data["last_hour"].to_i,
  "source_recent_keys" => current_recent_keys,
  "visitors" => events
}

File.write(ENV.fetch("VISITOR_DATA_OUTPUT", "/tmp/visitor-locations.json"), JSON.pretty_generate(output) + "\n")
