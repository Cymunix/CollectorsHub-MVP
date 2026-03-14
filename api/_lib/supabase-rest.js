function firstEnv(names) {
  for (var i = 0; i < names.length; i++) {
    var value = process.env[names[i]];
    if (value) {
      return value;
    }
  }
  return "";
}

function requiredEnv(names, label) {
  var value = firstEnv(names);
  if (!value) {
    throw new Error(
      "Missing required environment variable: " + label +
      ". Set one of [" + names.join(", ") + "] in your deployment/local env."
    );
  }
  return value;
}

function supabaseConfig() {
  return {
    url: requiredEnv(
      ["SUPABASE_URL", "SUPABASE_PROJECT_URL", "NEXT_PUBLIC_SUPABASE_URL", "VITE_SUPABASE_URL", "PUBLIC_SUPABASE_URL"],
      "SUPABASE_URL"
    ).replace(/\/$/, ""),
    serviceRoleKey: requiredEnv(
      ["SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEY", "SERVICE_ROLE_KEY"],
      "SUPABASE_SERVICE_ROLE_KEY"
    )
  };
}

async function supabaseRequest(path, options) {
  var config = supabaseConfig();
  var requestOptions = options || {};
  var headers = Object.assign({}, requestOptions.headers || {}, {
    apikey: config.serviceRoleKey,
    Authorization: "Bearer " + config.serviceRoleKey
  });

  var response = await fetch(config.url + "/rest/v1/" + path, {
    method: requestOptions.method || "GET",
    headers: headers,
    body: requestOptions.body
  });

  var text = await response.text();
  var data = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (error) {
      data = text;
    }
  }

  if (!response.ok) {
    throw new Error("Supabase REST request failed with status " + response.status + ": " + text);
  }

  return data;
}

module.exports = {
  supabaseRequest: supabaseRequest
};
