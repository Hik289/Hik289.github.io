require "json"
require "net/http"
require "time"
require "uri"

SITE_KEY = "a62ninj09x"
MAX_LOCATIONS = 60

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

def region_cache(path)
  return {} unless File.exist?(path)
  data = JSON.parse(File.read(path))
  Array(data["visitors"]).each_with_object({}) do |visitor, cache|
    next unless visitor["lat"] && visitor["lon"]
    cache[coordinate_key(visitor)] = {
      "city" => visitor["city"],
      "region" => visitor["region"],
      "country" => visitor["country"]
    }
  end
rescue JSON::ParserError
  {}
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

headers = { "X-Requested-With" => "XMLHttpRequest", "User-Agent" => "Hik289.github.io visitor map updater" }
base = "https://whos.amung.us/stats/data/?k=#{SITE_KEY}&v=free"
live_data = fetch_json("#{base}&pins=new", headers)
recent_data = fetch_json("#{base}&pins=old", headers)
live_points = Array(live_data["pins"]).map { |point| point.merge("status" => "live") }
recent_points = Array(recent_data["pins"]).map { |point| point.merge("status" => "recent") }
points = (live_points + recent_points).uniq { |point| coordinate_key(point) }.first(MAX_LOCATIONS)
cache = region_cache(ENV.fetch("PREVIOUS_VISITOR_DATA", "/tmp/visitor-locations-previous.json"))

visitors = points.map do |point|
  key = coordinate_key(point)
  location = cache[key]
  unless location
    location = reverse_geocode(point)
    sleep 1.1
  end
  {
    "city" => point["city"] || location["city"],
    "region" => location["region"],
    "country" => location["country"],
    "country_code" => point["country_code"],
    "lat" => point["lat"].to_f.round(3),
    "lon" => point["lon"].to_f.round(3),
    "status" => point["status"],
    "age_s" => point["time"]
  }
end

output = {
  "updated_at" => Time.now.utc.iso8601,
  "online_now" => live_data["total_count"].to_i,
  "locations" => visitors.length,
  "visitors" => visitors
}

File.write(ENV.fetch("VISITOR_DATA_OUTPUT", "/tmp/visitor-locations.json"), JSON.pretty_generate(output) + "\n")
