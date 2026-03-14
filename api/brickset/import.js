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

function isMissingColumnError(error, tableName, columnName) {
  var msg = String(error && error.message ? error.message : "");
  return msg.indexOf('"code":"42703"') >= 0 && msg.indexOf(tableName + "." + columnName) >= 0;
}

async function findDuplicateVariant(setNumber) {
  var encoded = encodeURIComponent(setNumber);
  try {
    return await supabaseRest.supabaseRequest(
      "variants?select=id,catalog_item_id,set_number&set_number=eq." + encoded + "&limit=1"
    );
  } catch (error) {
    if (!isMissingColumnError(error, "variants", "set_number")) {
      throw error;
    }

    // Compatibility mode for older schemas: dedupe by JSON attributes.set_number.
    return await supabaseRest.supabaseRequest(
      "variants?select=id,catalog_item_id,attributes&attributes->>set_number=eq." + encoded + "&limit=1"
    );
  }
}

async function insertVariantWithFallback(variantPayload) {
  var payload = Object.assign({}, variantPayload);

  for (var attempt = 0; attempt < 4; attempt++) {
    try {
      return await supabaseRest.supabaseRequest("variants", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Prefer: "return=representation"
        },
        body: JSON.stringify(payload)
      });
    } catch (error) {
      if (isMissingColumnError(error, "variants", "set_number")) {
        delete payload.set_number;
        continue;
      }
      if (isMissingColumnError(error, "variants", "piece_count")) {
        delete payload.piece_count;
        continue;
      }
      if (isMissingColumnError(error, "variants", "release_year")) {
        delete payload.release_year;
        continue;
      }
      throw error;
    }
  }

  throw new Error("Failed to insert variant due to schema mismatch");
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

    var duplicateRows = await findDuplicateVariant(mergedSet.setNumber);

    if (Array.isArray(duplicateRows) && duplicateRows.length > 0) {
      return responseUtils.sendJson(res, 409, {
        error: "This LEGO set already exists in the catalog.",
        existingVariant: duplicateRows[0]
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
    var pieceCount = asNumber(mergedSet.pieceCount);

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
        primary_image_url: mergedSet.imageUrl,
        is_active: true
      })
    });

    if (!Array.isArray(newCatalogItems) || newCatalogItems.length === 0) {
      throw new Error("Failed to create catalog item");
    }

    catalogItemId = newCatalogItems[0].id;
    createdCatalogItem = true;

    var newVariants = await insertVariantWithFallback({
      catalog_item_id: catalogItemId,
      set_number: mergedSet.setNumber,
      piece_count: pieceCount,
      edition: "Standard",
      release_year: releaseYear,
      platform_or_format: "LEGO Set",
      attributes: {
        brickset_theme: series,
        set_number: mergedSet.setNumber,
        piece_count: pieceCount
      },
      is_active: true
    });

    if (!Array.isArray(newVariants) || newVariants.length === 0) {
      throw new Error("Failed to create variant");
    }

    return responseUtils.sendJson(res, 200, {
      imported: true,
      catalogItemCreated: createdCatalogItem,
      catalogItemId: catalogItemId,
      variantId: newVariants[0].id,
      set: mergedSet
    });
  } catch (error) {
    return responseUtils.sendJson(res, 500, { error: error.message });
  }
};
