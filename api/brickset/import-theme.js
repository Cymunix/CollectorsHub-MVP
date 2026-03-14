const brickset = require("../_lib/brickset");
const responseUtils = require("../_lib/response");
const supabaseRest = require("../_lib/supabase-rest");

function asNumber(value) {
  if (value == null || value === "") {
    return null;
  }
  var num = Number(value);
  return Number.isFinite(num) ? num : null;
}

function normalizeText(value) {
  var s = String(value == null ? "" : value).trim();
  return s || null;
}

async function findDuplicateCatalogItem(setNumber) {
  if (!setNumber) {
    return null;
  }

  var rows = await supabaseRest.supabaseRequest(
    "catalog_items?select=id,name,set_number&set_number=eq." +
      encodeURIComponent(setNumber) +
      "&is_active=eq.true&limit=1"
  );

  return Array.isArray(rows) && rows.length ? rows[0] : null;
}

async function resolveFranchiseId(categoryId, franchiseId, fallbackName) {
  if (franchiseId) {
    return franchiseId;
  }

  var name = normalizeText(fallbackName);
  if (!name || !categoryId) {
    return null;
  }

  var existing = await supabaseRest.supabaseRequest(
    "catalog_franchises?select=id,name&category_id=eq." +
      encodeURIComponent(categoryId) +
      "&name=eq." +
      encodeURIComponent(name) +
      "&is_active=eq.true&limit=1"
  );
  if (Array.isArray(existing) && existing.length) {
    return existing[0].id;
  }

  var created = await supabaseRest.supabaseRequest("catalog_franchises", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify({
      category_id: categoryId,
      name: name,
      is_active: true
    })
  });

  return Array.isArray(created) && created.length ? created[0].id : null;
}

function getBricksetCredentials(req, body) {
  var headers = req && req.headers ? req.headers : {};
  var apiKey = String(headers["x-brickset-api-key"] || "").trim();
  var userHash = String(headers["x-brickset-user-hash"] || "").trim();

  if (!apiKey && body && typeof body === "object") {
    apiKey = String(body.apiKey || "").trim();
  }
  if (!userHash && body && typeof body === "object") {
    userHash = String(body.userHash || "").trim();
  }

  return {
    apiKey: apiKey || null,
    userHash: userHash || null
  };
}

async function importOneSet(setData, categoryId) {
  var duplicateItem = await findDuplicateCatalogItem(setData.setNumber);

  if (duplicateItem) {
    return { status: "skipped", reason: "duplicate" };
  }

  var itemName = setData.name;
  var series = normalizeText(setData.series) || normalizeText(setData.theme);
  var releaseYear = asNumber(setData.year);
  var franchiseId = await resolveFranchiseId(categoryId, normalizeText(setData.franchiseId), setData.theme);
  var catalogItemId = null;
  var newCatalogItems = await supabaseRest.supabaseRequest("catalog_items", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Prefer: "return=representation"
    },
    body: JSON.stringify({
      name: itemName,
      category_id: categoryId,
      subcategory_id: normalizeText(setData.subcategoryId),
      franchise_id: franchiseId,
      brand_or_publisher: normalizeText(setData.brandOrPublisher) || "LEGO",
      set_number: normalizeText(setData.setNumber),
      piece_count: asNumber(setData.pieceCount),
      edition: normalizeText(setData.edition),
      upc: normalizeText(setData.upc),
      series: series,
      release_year: releaseYear,
      description: normalizeText(setData.description),
      primary_image_url: setData.imageUrl,
      is_active: true
    })
  });

  if (!Array.isArray(newCatalogItems) || newCatalogItems.length === 0) {
    return { status: "error", reason: "Failed to create catalog item for: " + itemName };
  }

  catalogItemId = newCatalogItems[0].id;

  return { status: "imported", catalogItemId: catalogItemId };
}

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return responseUtils.methodNotAllowed(res, ["POST"]);
  }

  try {
    var body = req.body || {};
    if (typeof body === "string") {
      body = JSON.parse(body || "{}");
    }

    var theme = String(body.theme || "").trim();
    if (!theme) {
      return responseUtils.sendJson(res, 400, { error: "theme is required" });
    }

    var year = body.year ? asNumber(body.year) : null;
    var credentials = getBricksetCredentials(req, body);

    var categories = await supabaseRest.supabaseRequest(
      "catalog_categories?select=id,name&name=eq." +
        encodeURIComponent("Building Blocks") +
        "&limit=1"
    );

    if (!Array.isArray(categories) || categories.length === 0) {
      return responseUtils.sendJson(res, 500, {
        error: "Building Blocks category not found. Seed catalog categories first."
      });
    }

    var categoryId = categories[0].id;
    var sets = await brickset.getAllSetsByTheme(theme, year, credentials);

    if (!sets.length) {
      return responseUtils.sendJson(res, 200, {
        theme: theme,
        year: year,
        total: 0,
        imported: 0,
        skipped: 0,
        errorCount: 0,
        errors: []
      });
    }

    var importedCount = 0;
    var skippedCount = 0;
    var errors = [];

    for (var i = 0; i < sets.length; i++) {
      try {
        var result = await importOneSet(sets[i], categoryId);
        if (result.status === "imported") {
          importedCount++;
        } else if (result.status === "skipped") {
          skippedCount++;
        } else {
          errors.push({ setNumber: sets[i].setNumber, reason: result.reason });
        }
      } catch (setError) {
        errors.push({ setNumber: sets[i].setNumber, reason: setError.message });
      }
    }

    return responseUtils.sendJson(res, 200, {
      theme: theme,
      year: year,
      total: sets.length,
      imported: importedCount,
      skipped: skippedCount,
      errorCount: errors.length,
      errors: errors.slice(0, 20)
    });
  } catch (error) {
    return responseUtils.sendJson(res, 500, { error: error.message });
  }
};
