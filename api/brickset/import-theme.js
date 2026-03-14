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

async function importOneSet(setData, categoryId) {
  var duplicateRows = await findDuplicateVariant(setData.setNumber);

  if (Array.isArray(duplicateRows) && duplicateRows.length > 0) {
    return { status: "skipped", reason: "duplicate" };
  }

  var itemName = setData.name;
  var series = setData.theme || null;
  var releaseYear = asNumber(setData.year);
  var pieceCount = asNumber(setData.pieceCount);

  var existingItems = await supabaseRest.supabaseRequest(
    "catalog_items?select=id,name&name=eq." +
      encodeURIComponent(itemName) +
      "&category_id=eq." +
      encodeURIComponent(categoryId) +
      "&is_active=eq.true&limit=1"
  );

  var catalogItemId = null;

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
      return { status: "error", reason: "Failed to create catalog item for: " + itemName };
    }

    catalogItemId = newCatalogItems[0].id;
  }

  var newVariants = await insertVariantWithFallback({
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
  });

  if (!Array.isArray(newVariants) || newVariants.length === 0) {
    return { status: "error", reason: "Failed to create variant for: " + setData.setNumber };
  }

  return { status: "imported", catalogItemId: catalogItemId, variantId: newVariants[0].id };
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
