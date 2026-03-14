const brickset = require("../_lib/brickset");
const responseUtils = require("../_lib/response");

module.exports = async function handler(req, res) {
  if (req.method !== "GET") {
    return responseUtils.methodNotAllowed(res, ["GET"]);
  }

  try {
    var themes = await brickset.getThemes();
    return responseUtils.sendJson(res, 200, { count: themes.length, themes: themes });
  } catch (error) {
    return responseUtils.sendJson(res, 500, { error: error.message });
  }
};
