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
    var credentials = getBricksetCredentials(req);
    var themes = await brickset.getThemes(credentials);
    return responseUtils.sendJson(res, 200, { count: themes.length, themes: themes });
  } catch (error) {
    return responseUtils.sendJson(res, 500, { error: error.message });
  }
};
