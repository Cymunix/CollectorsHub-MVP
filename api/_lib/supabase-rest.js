function requiredEnv(name) {
  var value = process.env[name];
  if (!value) {
    throw new Error("Missing required environment variable: " + name);
  }
  return value;
}

function supabaseConfig() {
  return {
    url: requiredEnv("SUPABASE_URL").replace(/\/$/, ""),
    serviceRoleKey: requiredEnv("SUPABASE_SERVICE_ROLE_KEY")
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
