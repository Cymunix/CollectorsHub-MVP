function requiredEnv(name) {
  var value = process.env[name];
  if (!value) {
    throw new Error("Missing required environment variable: " + name);
  }
  return value;
}

function tryParseJson(value) {
  if (typeof value !== "string") {
    return value;
  }
  try {
    return JSON.parse(value);
  } catch (error) {
    return value;
  }
}

function unwrapPayload(raw) {
  var parsed = tryParseJson(raw);
  if (parsed && typeof parsed === "object" && parsed.d != null) {
    return tryParseJson(parsed.d);
  }
  return parsed;
}

function pickSetNumber(source) {
  return String(
    source.setNumber ||
    source.number ||
    source.set_number ||
    source.numberVariant ||
    source.number_variant ||
    ""
  ).trim();
}

function normalizeSet(source) {
  return {
    setNumber: pickSetNumber(source),
    name: source.name || source.setName || source.set_name || null,
    year: source.year || source.released || source.releaseYear || null,
    theme: source.theme || source.themeGroup || source.category || null,
    pieceCount: source.pieces || source.pieceCount || source.piece_count || null,
    minifigCount: source.minifigs || source.minifigCount || source.minifig_count || null,
    imageUrl:
      source.image ||
      source.imageUrl ||
      source.imageURL ||
      source.thumbnailURL ||
      source.thumbnailUrl ||
      source.largeThumbnailURL ||
      null,
    raw: source
  };
}

async function callBrickset(endpoint, paramsObject) {
  var apiKey = requiredEnv("BRICKSET_API_KEY");
  var baseUrl = process.env.BRICKSET_API_BASE_URL || "https://brickset.com/api/v3.asmx";
  var userHash = process.env.BRICKSET_USER_HASH || "";

  var query = new URLSearchParams();
  query.set("apiKey", apiKey);
  if (userHash) {
    query.set("userHash", userHash);
  }
  if (paramsObject && Object.keys(paramsObject).length > 0) {
    query.set("params", JSON.stringify(paramsObject));
  }

  var url = baseUrl.replace(/\/$/, "") + "/" + endpoint + "?" + query.toString();
  var response = await fetch(url, { method: "GET" });
  var text = await response.text();

  if (!response.ok) {
    throw new Error("Brickset request failed with status " + response.status + ": " + text.slice(0, 300));
  }

  return unwrapPayload(text);
}

function extractSetList(payload) {
  if (Array.isArray(payload)) {
    return payload;
  }
  if (!payload || typeof payload !== "object") {
    return [];
  }
  if (Array.isArray(payload.sets)) {
    return payload.sets;
  }
  if (Array.isArray(payload.matches)) {
    return payload.matches;
  }
  if (Array.isArray(payload.results)) {
    return payload.results;
  }
  return [];
}

async function searchSets(query) {
  var payload = await callBrickset("getSets", {
    query: query,
    pageSize: 50,
    pageNumber: 1
  });

  return extractSetList(payload).map(normalizeSet).filter(function (set) {
    return Boolean(set.setNumber && set.name);
  });
}

async function getSetByNumber(setNumber) {
  var payload = await callBrickset("getSets", {
    setNumber: setNumber,
    pageSize: 1,
    pageNumber: 1
  });

  var sets = extractSetList(payload);
  if (!sets.length) {
    return null;
  }

  return normalizeSet(sets[0]);
}

async function getThemes() {
  var payload = await callBrickset("getThemes", {});
  if (payload && Array.isArray(payload.themes)) {
    return payload.themes
      .map(function (t) { return { theme: t.theme, setCount: t.setCount || 0 }; })
      .filter(function (t) { return Boolean(t.theme); })
      .sort(function (a, b) { return a.theme.localeCompare(b.theme); });
  }
  return [];
}

async function getSetsByThemePage(theme, pageNumber, year) {
  var params = {
    theme: theme,
    pageSize: 500,
    pageNumber: pageNumber
  };
  if (year) {
    params.year = year;
  }
  var payload = await callBrickset("getSets", params);
  return extractSetList(payload).map(normalizeSet).filter(function (set) {
    return Boolean(set.setNumber && set.name);
  });
}

async function getAllSetsByTheme(theme, year) {
  var allSets = [];
  var pageNumber = 1;
  while (true) {
    var page = await getSetsByThemePage(theme, pageNumber, year);
    allSets = allSets.concat(page);
    if (page.length < 500) {
      break;
    }
    pageNumber++;
  }
  return allSets;
}

module.exports = {
  searchSets: searchSets,
  getSetByNumber: getSetByNumber,
  getThemes: getThemes,
  getSetsByThemePage: getSetsByThemePage,
  getAllSetsByTheme: getAllSetsByTheme
};
