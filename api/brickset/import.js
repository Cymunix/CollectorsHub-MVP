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

    var duplicateRows = await supabaseRest.supabaseRequest(
      "variants?select=id,catalog_item_id,set_number&set_number=eq." + encodeURIComponent(setData.setNumber) + "&limit=1"
    );

    if (Array.isArray(duplicateRows) && duplicateRows.length > 0) {
      return responseUtils.sendJson(res, 409, {
        error: "This LEGO set already exists in the catalog.",
        existingVariant: duplicateRows[0]
      });
    }

    var categories = await supabaseRest.supabaseRequest(
      "catalog_categories?select=id,name&name=eq." + encodeURIComponent("Building Blocks") + "&limit=1"
    );

    if (!Array.isArray(categories) || categories.length === 0) {
      return responseUtils.sendJson(res, 500, {
        error: "Building Blocks category not found. Seed catalog categories first."
      });
    }

    var categoryId = categories[0].id;
    var itemName = setData.name;
    var series = setData.theme || null;
    var releaseYear = asNumber(setData.year);
    var pieceCount = asNumber(setData.pieceCount);

    var existingItems = await supabaseRest.supabaseRequest(
      "catalog_items?select=id,name&name=eq." + encodeURIComponent(itemName) +
      "&category_id=eq." + encodeURIComponent(categoryId) +
      "&is_active=eq.true&limit=1"
    );

    var catalogItemId = null;
    var createdCatalogItem = false;

    if (Array.isArray(existingItems) && existingItems.length > 0) {
      catalogItemId = existingItems[0].id;
    } else {
      var newCatalogItems = await supabaseRest.supabaseRequest("catalog_items", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Prefer: "return=representation"
        },
        body: JSON.stringify({
          name: itemName,
          category_id: categoryId,
          brand_or_publisher: "LEGO",
          series: series,
          release_year: releaseYear,
          primary_image_url: setData.imageUrl,
          is_active: true
        })
      });

      if (!Array.isArray(newCatalogItems) || newCatalogItems.length === 0) {
        throw new Error("Failed to create catalog item");
      }

      catalogItemId = newCatalogItems[0].id;
      createdCatalogItem = true;
    }

    var newVariants = await supabaseRest.supabaseRequest("variants", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Prefer: "return=representation"
      },
      body: JSON.stringify({
        catalog_item_id: catalogItemId,
        set_number: setData.setNumber,
        piece_count: pieceCount,
        edition: "Standard",
        release_year: releaseYear,
        platform_or_format: "LEGO Set",
        attributes: {
          brickset_theme: series,
          set_number: setData.setNumber,
          piece_count: pieceCount
        },
        is_active: true
      })
    });

    if (!Array.isArray(newVariants) || newVariants.length === 0) {
      throw new Error("Failed to create variant");
    }

    return responseUtils.sendJson(res, 200, {
      imported: true,
      catalogItemCreated: createdCatalogItem,
      catalogItemId: catalogItemId,
      variantId: newVariants[0].id,
      set: setData
    });
  } catch (error) {
    return responseUtils.sendJson(res, 500, { error: error.message });
  }
};
