function requiredEnv(name) {
  var value = process.env[name];
  if (!value) {
    throw new Error("Missing required environment variable: " + name);
  }
  return value;
}

function firstEnv(names) {
  for (var i = 0; i < names.length; i++) {
    var value = process.env[names[i]];
    if (value) {
      return value;
    }
  }
  return "";
}

function requiredAnyEnv(names, label) {
  var value = firstEnv(names);
  if (!value) {
    throw new Error(
      "Missing required environment variable: " + label +
      ". Set one of [" + names.join(", ") + "] in Vercel project env vars and redeploy."
    );
  }
  return value;
}

function cleanString(value) {
  return String(value == null ? "" : value).trim();
}

function normalizeCredentials(credentials) {
  var source = credentials && typeof credentials === "object" ? credentials : {};
  var apiKey = cleanString(source.apiKey || source.key);
  var userHash = cleanString(source.userHash);
  return {
    apiKey: apiKey || null,
    userHash: userHash || null
  };
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

async function callBrickset(endpoint, paramsObject, credentials) {
  var cred = normalizeCredentials(credentials);
  var apiKey = cred.apiKey || requiredAnyEnv(
    [
      "BRICKSET_API_KEY",
      "BRICKSET_KEY",
      "BRICKSET_APIKEY",
      "NEXT_PUBLIC_BRICKSET_API_KEY",
      "PUBLIC_BRICKSET_API_KEY"
    ],
    "BRICKSET_API_KEY"
  );
  var baseUrl = process.env.BRICKSET_API_BASE_URL || "https://brickset.com/api/v3.asmx";
  var userHash = cred.userHash || firstEnv([
    "BRICKSET_USER_HASH",
    "BRICKSET_USERHASH",
    "NEXT_PUBLIC_BRICKSET_USER_HASH",
    "PUBLIC_BRICKSET_USER_HASH"
  ]) || "";

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

async function searchSets(query, credentials) {
  var payload = await callBrickset("getSets", {
    query: query,
    pageSize: 50,
    pageNumber: 1
  }, credentials);

  return extractSetList(payload).map(normalizeSet).filter(function (set) {
    return Boolean(set.setNumber && set.name);
  });
}

async function getSetByNumber(setNumber, credentials) {
  var requested = String(setNumber || "").trim();
  if (!requested) {
    return null;
  }

  function findBestMatch(rawSets, target) {
    var normalized = (rawSets || []).map(normalizeSet).filter(function (set) {
      return Boolean(set.setNumber && set.name);
    });
    if (!normalized.length) {
      return null;
    }

    var exact = normalized.find(function (set) {
      return String(set.setNumber).toLowerCase() === target.toLowerCase();
    });
    if (exact) {
      return exact;
    }

    var base = target.split("-")[0];
    var startsWithBase = normalized.find(function (set) {
      return String(set.setNumber).toLowerCase().indexOf(base.toLowerCase() + "-") === 0;
    });
    if (startsWithBase) {
      return startsWithBase;
    }

    return normalized[0];
  }

  // Attempt 1: strict setNumber match
  var payload1 = await callBrickset("getSets", {
    setNumber: requested,
    pageSize: 25,
    pageNumber: 1
  }, credentials);
  var match1 = findBestMatch(extractSetList(payload1), requested);
  if (match1) {
    return match1;
  }

  // Attempt 2: base number (handles requests like 75257-1)
  var baseNumber = requested.split("-")[0];
  if (baseNumber && baseNumber !== requested) {
    var payload2 = await callBrickset("getSets", {
      setNumber: baseNumber,
      pageSize: 50,
      pageNumber: 1
    }, credentials);
    var match2 = findBestMatch(extractSetList(payload2), requested);
    if (match2) {
      return match2;
    }
  }

  // Attempt 3: query search fallback
  var payload3 = await callBrickset("getSets", {
    query: requested,
    pageSize: 50,
    pageNumber: 1
  }, credentials);
  return findBestMatch(extractSetList(payload3), requested);
}

async function getThemes(credentials) {
  var payload = await callBrickset("getThemes", {}, credentials);
  if (payload && Array.isArray(payload.themes)) {
    return payload.themes
      .map(function (t) { return { theme: t.theme, setCount: t.setCount || 0 }; })
      .filter(function (t) { return Boolean(t.theme); })
      .sort(function (a, b) { return a.theme.localeCompare(b.theme); });
  }
  return [];
}

async function getSetsByThemePage(theme, pageNumber, year, credentials) {
  var params = {
    theme: theme,
    pageSize: 500,
    pageNumber: pageNumber
  };
  if (year) {
    params.year = year;
  }
  var payload = await callBrickset("getSets", params, credentials);
  return extractSetList(payload).map(normalizeSet).filter(function (set) {
    return Boolean(set.setNumber && set.name);
  });
}

async function getAllSetsByTheme(theme, year, credentials) {
  var allSets = [];
  var pageNumber = 1;
  while (true) {
    var page = await getSetsByThemePage(theme, pageNumber, year, credentials);
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
