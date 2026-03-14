const brickset = require("../../_lib/brickset");
const responseUtils = require("../../_lib/response");

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
    var setNumber = "";
    if (req.query && req.query.setNumber) {
      setNumber = String(req.query.setNumber).trim();
    } else {
      var requestUrl = new URL(req.url, "http://localhost");
      var segments = requestUrl.pathname.split("/").filter(Boolean);
      setNumber = String(segments[segments.length - 1] || "").trim();
    }

    if (!setNumber) {
      return responseUtils.sendJson(res, 400, { error: "setNumber is required" });
    }

    var credentials = getBricksetCredentials(req);
    var setData = await brickset.getSetByNumber(setNumber, credentials);
    if (!setData) {
      return responseUtils.sendJson(res, 404, { error: "Set not found" });
    }

    return responseUtils.sendJson(res, 200, setData);
  } catch (error) {
    return responseUtils.sendJson(res, 500, { error: error.message });
  }
};
