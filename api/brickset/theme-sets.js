const brickset = require("../_lib/brickset");
const responseUtils = require("../_lib/response");

function getBricksetCredentials(req) {
  var headers = req && req.headers ? req.headers : {};
  var apiKey = String(headers["x-brickset-api-key"] || "").trim();
  var userHash = String(headers["x-brickset-user-hash"] || "").trim();
  return {
    apiKey: apiKey || null,
    userHash: userHash || null
  };
}

module.exports = async function handler(req, res) {
  if (req.method !== "GET") {
    return responseUtils.methodNotAllowed(res, ["GET"]);
  }

  try {
    var requestUrl = new URL(req.url, "http://localhost");
    var theme = String(requestUrl.searchParams.get("theme") || "").trim();
    var yearRaw = requestUrl.searchParams.get("year");
    var limitRaw = requestUrl.searchParams.get("limit");
    var year = yearRaw ? Number(yearRaw) : undefined;
    var limit = limitRaw ? Number(limitRaw) : 20;

    if (!theme) {
      return responseUtils.sendJson(res, 400, { error: "theme is required" });
    }

    if (!Number.isFinite(limit) || limit < 1) {
      limit = 20;
    }
    if (limit > 50) {
      limit = 50;
    }

    var credentials = getBricksetCredentials(req);
    var sets = await brickset.getSetsByThemePage(theme, 1, year, credentials);
    var sample = sets.slice(0, limit);

    return responseUtils.sendJson(res, 200, {
      theme: theme,
      year: Number.isFinite(year) ? year : null,
      count: sample.length,
      results: sample
    });
  } catch (error) {
    return responseUtils.sendJson(res, 500, { error: error.message });
  }
};
