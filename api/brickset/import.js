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

function buildCatalogItemDescription(setData) {
  var parts = ["Imported from Brickset."];
  if (setData.setNumber) {
    parts.push("Set Number: " + setData.setNumber + ".");
  }
  if (setData.pieceCount != null) {
    parts.push("Piece Count: " + setData.pieceCount + ".");
  }
  if (setData.theme) {
    parts.push("Theme: " + setData.theme + ".");
  }
  return parts.join(" ");
}

async function findDuplicateCatalogItem(setData, categoryId) {
  var rows = await supabaseRest.supabaseRequest(
    "catalog_items?select=id,name,series,release_year,description&category_id=eq." +
      encodeURIComponent(categoryId) +
      "&name=eq." +
      encodeURIComponent(setData.name) +
      "&is_active=eq.true&limit=20"
  );

  if (!Array.isArray(rows) || !rows.length) {
    return null;
  }

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i];
    var description = String(row.description || "");
    if (setData.setNumber && description.indexOf("Set Number: " + setData.setNumber) >= 0) {
      return row;
    }
    if (
      String(row.series || "") === String(setData.theme || "") &&
      Number(row.release_year || 0) === Number(setData.year || 0)
    ) {
      return row;
    }
  }

  return null;
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

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    return responseUtils.methodNotAllowed(res, ["POST"]);
  }

  try {
    var body = req.body || {};
    if (typeof body === "string") {
      body = JSON.parse(body || "{}");
    }

    var requestedSetNumber = String(body.setNumber || "").trim();
    if (!requestedSetNumber) {
      return responseUtils.sendJson(res, 400, { error: "setNumber is required" });
    }

    var credentials = getBricksetCredentials(req, body);
    var setData = await brickset.getSetByNumber(requestedSetNumber, credentials);
    if (!setData) {
      return responseUtils.sendJson(res, 404, { error: "Set not found in Brickset" });
    }

    var mergedSet = {
      setNumber: requestedSetNumber,
      name: normalizeText(body.name) || setData.name,
      theme: normalizeText(body.theme) || setData.theme,
      year: asNumber(body.year) != null ? asNumber(body.year) : setData.year,
      pieceCount: asNumber(body.pieceCount) != null ? asNumber(body.pieceCount) : setData.pieceCount,
      imageUrl: normalizeText(body.imageUrl) || setData.imageUrl
    };

    var duplicateItem = await findDuplicateCatalogItem(mergedSet, categoryId);

    if (duplicateItem) {
      return responseUtils.sendJson(res, 409, {
        error: "This LEGO set already exists in the catalog.",
        existingCatalogItem: duplicateItem
      });
    }

    var categoryId = normalizeText(body.categoryId);
    if (!categoryId) {
      var categories = await supabaseRest.supabaseRequest(
        "catalog_categories?select=id,name&name=eq." + encodeURIComponent("Building Blocks") + "&limit=1"
      );

      if (!Array.isArray(categories) || categories.length === 0) {
        return responseUtils.sendJson(res, 500, {
          error: "Building Blocks category not found. Seed catalog categories first."
        });
      }
      categoryId = categories[0].id;
    }

    var subcategoryId = normalizeText(body.subcategoryId);
    var itemName = mergedSet.name;
    var series = mergedSet.theme || null;
    var releaseYear = asNumber(mergedSet.year);

    var catalogItemId = null;
    var createdCatalogItem = false;
    var newCatalogItems = await supabaseRest.supabaseRequest("catalog_items", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        name: itemName,
        category_id: categoryId,
        subcategory_id: subcategoryId,
        brand_or_publisher: "LEGO",
        series: series,
        release_year: releaseYear,
        description: buildCatalogItemDescription(mergedSet),
        primary_image_url: mergedSet.imageUrl,
        is_active: true
      })
    });

    if (!Array.isArray(newCatalogItems) || newCatalogItems.length === 0) {
      throw new Error("Failed to create catalog item");
    }

    catalogItemId = newCatalogItems[0].id;
    createdCatalogItem = true;

    return responseUtils.sendJson(res, 200, {
      imported: true,
      catalogItemCreated: createdCatalogItem,
      catalogItemId: catalogItemId,
      set: mergedSet
    });
  } catch (error) {
    return responseUtils.sendJson(res, 500, { error: error.message });
  }
};
