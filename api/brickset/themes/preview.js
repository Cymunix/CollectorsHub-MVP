const { getSetsByThemePage } = require("../../_lib/brickset");
const { sendJson, methodNotAllowed } = require("../../_lib/response");

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
  if (req.method !== "GET") return methodNotAllowed(res, ["GET"]);

  const theme = req.query.theme;
  const year = req.query.year ? parseInt(req.query.year, 10) : undefined;

  if (!theme) return sendJson(res, 400, { error: "theme is required" });

  try {
    const credentials = getBricksetCredentials(req);
    // Fetch just the first page — the pageSize 1 trick lets Brickset tell us the total
    // but v3 doesn't return a total count directly. Instead we fetch page 1 with pageSize 1
    // and count matches. For accuracy we fetch the first page at 500 and note whether it's full.
    // A true count needs getAllSetsByTheme but that may be slow for large themes.
    // We do a quick single-page call: if < 500 results it's the true total; otherwise report "500+".
    const firstPage = await getSetsByThemePage(theme, 1, year, credentials);
    const total = firstPage.length < 500 ? firstPage.length : null; // null = has more pages

    if (total !== null) {
      return sendJson(res, 200, { theme, year: year || null, total });
    }

    // Has more than 500 — do a second call to better estimate, but cap at 2 pages for speed
    const secondPage = await getSetsByThemePage(theme, 2, year, credentials);
    if (secondPage.length < 500) {
      return sendJson(res, 200, { theme, year: year || null, total: 500 + secondPage.length });
    }

    // Still more — just report "1000+" so the user knows it's large
    return sendJson(res, 200, { theme, year: year || null, total: "1000+" });
  } catch (err) {
    return sendJson(res, 502, { error: err.message || "Brickset request failed" });
  }
};
