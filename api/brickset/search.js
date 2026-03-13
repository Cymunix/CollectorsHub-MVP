const brickset = require("../_lib/brickset");
const responseUtils = require("../_lib/response");

module.exports = async function handler(req, res) {
  if (req.method !== "GET") {
    return responseUtils.methodNotAllowed(res, ["GET"]);
  }

  try {
    var requestUrl = new URL(req.url, "http://localhost");
    var query = (requestUrl.searchParams.get("q") || "").trim();

    if (!query) {
      return responseUtils.sendJson(res, 400, { error: "Query parameter q is required" });
    }

    var sets = await brickset.searchSets(query);
    return responseUtils.sendJson(res, 200, {
      query: query,
      count: sets.length,
      results: sets
    });
  } catch (error) {
    return responseUtils.sendJson(res, 500, { error: error.message });
  }
};
