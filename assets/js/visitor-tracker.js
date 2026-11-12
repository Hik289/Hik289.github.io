(() => {
  const api = "https://xinyuan-visitor-api.opendelta4.chatgpt.site/api/visitors";
  const list = document.getElementById("visitor-log-list");
  const pins = document.getElementById("visitor-map-pins");
  const hasMap = Boolean(list && pins);
  const pause = (milliseconds) => new Promise((resolve) => window.setTimeout(resolve, milliseconds));
  const newEventId = () => globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const relativeTime = (seconds) => {
    const value = Math.max(0, Number(seconds) || 0);
    if (value < 60) return "just now";
    if (value < 3600) return `${Math.floor(value / 60)} min ago`;
    if (value < 86400) return `${Math.floor(value / 3600)} hr ago`;
    return `${Math.floor(value / 86400)} day${value < 172800 ? "" : "s"} ago`;
  };
  const countryFlag = (code) => {
    if (!code || code.length !== 2) return "🌐";
    return String.fromCodePoint(...code.toUpperCase().split("").map((letter) => 127397 + letter.charCodeAt(0)));
  };
  const placeLabel = (visitor) => [visitor.city, visitor.region, visitor.country]
    .filter((value, position, values) => value && values.indexOf(value) === position)
    .join(", ") || "Unknown region";
  const secondsSince = (visitor, updatedAt) => {
    const timestamp = Date.parse(visitor.last_seen || updatedAt || "");
    return Number.isFinite(timestamp) ? Math.max(0, (Date.now() - timestamp) / 1000) : visitor.age_s;
  };
  const render = (data) => {
    if (!hasMap) return;
    const visitors = Array.isArray(data.visitors) ? [...data.visitors] : [];
    visitors.sort((left, right) => {
      const liveDifference = Number(right.status === "live") - Number(left.status === "live");
      if (liveDifference) return liveDifference;
      return Date.parse(right.last_seen || data.updated_at || "") - Date.parse(left.last_seen || data.updated_at || "");
    });
    list.replaceChildren();
    pins.replaceChildren();
    if (!visitors.length) {
      const empty = document.createElement("li");
      empty.className = "visitor-log-empty";
      empty.textContent = "No visits yet.";
      list.appendChild(empty);
      return;
    }
    const plottedLocations = new Set();
    visitors.forEach((visitor, index) => {
      const latitude = Number(visitor.lat);
      const longitude = Number(visitor.lon);
      if (Number.isFinite(latitude) && Number.isFinite(longitude)) {
        const locationKey = `${latitude.toFixed(3)},${longitude.toFixed(3)}`;
        if (!plottedLocations.has(locationKey)) {
          plottedLocations.add(locationKey);
          const pin = document.createElement("i");
          pin.className = visitor.status === "live" ? "visitor-map-pin is-live" : "visitor-map-pin";
          pin.style.left = `${Math.min(100, Math.max(0, ((longitude + 180) / 360) * 100))}%`;
          pin.style.top = `${Math.min(100, Math.max(0, ((90 - latitude) / 180) * 100))}%`;
          pin.title = placeLabel(visitor);
          pins.appendChild(pin);
        }
      }
      const item = document.createElement("li");
      const identity = document.createElement("span");
      const location = document.createElement("span");
      const time = document.createElement("time");
      identity.className = "visitor-log-identity";
      location.className = "visitor-log-location";
      time.className = "visitor-log-time";
      identity.textContent = `Visitor ${String(index + 1).padStart(2, "0")}`;
      location.textContent = `${countryFlag(visitor.country_code)} ${placeLabel(visitor)}`;
      time.dateTime = visitor.last_seen || "";
      time.textContent = Number(visitor.live_visits) > 0 ? "Live" : relativeTime(secondsSince(visitor, data.updated_at));
      item.append(identity, location, time);
      list.appendChild(item);
    });
  };
  const showUnavailable = () => {
    if (!hasMap) return;
    const empty = document.createElement("li");
    empty.className = "visitor-log-empty";
    empty.textContent = "Visitor list is temporarily unavailable.";
    list.replaceChildren(empty);
  };
  const locate = async () => {
    const response = await fetch("https://ipwho.is/", { cache: "no-store" });
    if (!response.ok) throw new Error("Location unavailable");
    const location = await response.json();
    if (location.success === false) throw new Error("Location unavailable");
    return {
      city: location.city,
      region: location.region,
      country: location.country,
      country_code: location.country_code,
      latitude: location.latitude,
      longitude: location.longitude
    };
  };
  let eventId = newEventId();
  let recorded = false;
  let postStarted = false;
  let recording = false;
  let lastRecordedAt = 0;
  const post = async (location = {}) => {
    postStarted = true;
    const response = await fetch(`${api}?v=${Date.now()}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ...location, event_id: eventId, include_visitors: hasMap }),
      cache: "no-store",
      keepalive: true
    });
    if (!response.ok) throw new Error("Visit could not be recorded");
    const data = await response.json();
    recorded = true;
    lastRecordedAt = Date.now();
    render(data);
    return data;
  };
  const postWithRetry = async (location) => {
    const delays = [0, 700, 2000];
    let error;
    for (const delay of delays) {
      if (delay) await pause(delay);
      try {
        return await post(location);
      } catch (caught) {
        error = caught;
      }
    }
    throw error;
  };
  const recordVisit = async () => {
    if (recording || recorded) return;
    recording = true;
    const locationPromise = locate().catch(() => null);
    const earlyLocation = await Promise.race([locationPromise, pause(600).then(() => null)]);
    if (recorded) {
      recording = false;
      return;
    }
    try {
      await postWithRetry(earlyLocation || {});
      if (!earlyLocation) {
        const resolvedLocation = await locationPromise;
        if (resolvedLocation) await post(resolvedLocation).catch(() => {});
      }
    } catch (_error) {
      showUnavailable();
    } finally {
      recording = false;
    }
  };
  const refresh = async () => {
    if (!hasMap) return;
    try {
      const response = await fetch(`${api}?v=${Date.now()}`, { cache: "no-store" });
      if (!response.ok) throw new Error("Visitor data unavailable");
      render(await response.json());
    } catch (_error) {
      showUnavailable();
    }
  };
  const sendFallback = () => {
    if (recorded || postStarted) return;
    const body = JSON.stringify({ event_id: eventId, include_visitors: false });
    const queued = navigator.sendBeacon?.(api, new Blob([body], { type: "text/plain;charset=UTF-8" }));
    if (queued) {
      recorded = true;
      postStarted = true;
      lastRecordedAt = Date.now();
      return;
    }
    fetch(api, { method: "POST", body, keepalive: true, cache: "no-store" }).catch(() => {});
  };
  recordVisit();
  if (hasMap) window.setInterval(refresh, 60 * 1000);
  window.addEventListener("pagehide", sendFallback);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) return;
    if (Date.now() - lastRecordedAt >= 10 * 60 * 1000) {
      eventId = newEventId();
      recorded = false;
      postStarted = false;
      recordVisit();
    } else {
      refresh();
    }
  });
})();
