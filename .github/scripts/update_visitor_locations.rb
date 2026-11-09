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

def parse_time(value, fallback)
  value ? Time.parse(value).utc : fallback
rescue ArgumentError
  fallback
end

now = Time.now.utc
previous_path = ENV.fetch("PREVIOUS_VISITOR_DATA", "/tmp/visitor-locations-previous.json")
previous_data = load_previous(previous_path)
previous_updated_at = parse_time(previous_data["updated_at"], now)
location_cache = region_cache(previous_data)
previous_visitors = Array(previous_data["visitors"]).each_with_object({}) do |visitor, indexed|
  next unless visitor["lat"] && visitor["lon"]
  indexed[coordinate_key(visitor)] = visitor
end

headers = { "X-Requested-With" => "XMLHttpRequest", "User-Agent" => "Hik289.github.io visitor map updater" }
base = "https://whos.amung.us/stats/data/?k=#{SITE_KEY}&v=free"
live_data = fetch_json("#{base}&pins=new", headers)
recent_data = fetch_json("#{base}&pins=old", headers)
live_points = Array(live_data["pins"]).map { |point| point.merge("status" => "live") }
recent_points = Array(recent_data["pins"]).map { |point| point.merge("status" => "seen") }
recent_counts = Hash.new(0)
recent_points.each { |point| recent_counts[coordinate_key(point)] += 1 }

current_points = {}
recent_points.each { |point| current_points[coordinate_key(point)] ||= point }
live_points.each { |point| current_points[coordinate_key(point)] = point }

current_points.each do |key, point|
  previous = previous_visitors[key] || {}
  location = location_cache[key] || {}
  if location["region"].nil? || location["country"].nil?
    geocoded = reverse_geocode(point)
    location = location.merge(geocoded) { |_field, existing, replacement| existing || replacement }
    sleep 1.1
  end

  observed_at = point["time"] ? now - point["time"].to_i : now
  first_seen = parse_time(previous["first_seen"] || previous["last_seen"], previous_updated_at)
  last_seen = parse_time(previous["last_seen"], previous_updated_at)
  last_seen = observed_at if previous.empty? || (point["status"] == "live" && observed_at > last_seen)

  previous_visitors[key] = {
    "city" => point["city"] || previous["city"] || location["city"],
    "region" => previous["region"] || location["region"],
    "country" => previous["country"] || location["country"],
    "country_code" => point["country_code"] || previous["country_code"],
    "lat" => point["lat"].to_f.round(3),
    "lon" => point["lon"].to_f.round(3),
    "status" => point["status"],
    "visits" => [previous["visits"].to_i, recent_counts[key], 1].max,
    "first_seen" => first_seen.iso8601,
    "last_seen" => last_seen.iso8601,
    "age_s" => [(now - last_seen).to_i, 0].max
  }
end

visitors = previous_visitors.values.map do |visitor|
  last_seen = parse_time(visitor["last_seen"], previous_updated_at)
  visitor.merge(
    "status" => current_points[coordinate_key(visitor)]&.fetch("status", "seen") || "seen",
    "visits" => [visitor["visits"].to_i, 1].max,
    "first_seen" => parse_time(visitor["first_seen"], last_seen).iso8601,
    "last_seen" => last_seen.iso8601,
    "age_s" => [(now - last_seen).to_i, 0].max
  )
end.sort_by { |visitor| visitor["last_seen"] }.reverse

output = {
  "updated_at" => now.iso8601,
  "online_now" => live_data["total_count"].to_i,
  "locations" => visitors.length,
  "visits_total" => visitors.sum { |visitor| visitor["visits"] },
  "visitors" => visitors
}

File.write(ENV.fetch("VISITOR_DATA_OUTPUT", "/tmp/visitor-locations.json"), JSON.pretty_generate(output) + "\n")
