import express from "express";
import axios from "axios";
import { SignJWT, importPKCS8, exportJWK } from "jose";
import fs from "fs";
import path from "path";

const app = express();
app.use(express.json());

// =====================
// ENV
// =====================
const {
  CLIENT_ID,
  CLIENT_SECRET,
  PRIVATE_KEY,
  AUDIENCE,
  TESLA_AUTH_URL,
  ACCOUNT_ID,
  VIN
} = process.env;

// =====================
// HOME
// =====================
app.get("/", (req, res) => {
  res.send("Greencharge Tesla Proxy OK v1");
});

// =====================
// JWKS
// =====================
app.get("/.well-known/jwks.json", async (req, res) => {
  try {
    const privateKeyPem = PRIVATE_KEY.replace(/\\n/g, "\n");
    const key = await importPKCS8(privateKeyPem, "ES256");
    const jwk = await exportJWK(key);

    delete jwk.d;
    jwk.use = "sig";
    jwk.alg = "ES256";
    jwk.kid = "greencharge-key-1";

    console.log("🔑 JWKS generato correttamente");
    res.json({ keys: [jwk] });
  } catch (err) {
    console.error("❌ Errore JWKS:", err);
    res.status(500).json({ error: err.message });
  }
});

// =====================
// Tesla public key
// =====================
app.get("/.well-known/appspecific/com.tesla.3p.public-key.pem", (req, res) => {
  try {
    const keyPath = path.join(process.cwd(), "keys", "tesla-public-key.pem");
    const pem = fs.readFileSync(keyPath, "utf8");
    res.setHeader("Content-Type", "application/x-pem-file");
    res.status(200).send(pem);
    console.log("🔑 Tesla public key servita");
  } catch (err) {
    console.error("❌ Errore lettura Tesla public key:", err);
    res.status(500).send("Public key not available");
  }
});

// =====================
// Partner token
// =====================
let cachedToken = null;
let tokenExpiresAt = 0;

async function getPartnerToken() {
  try {
    if (cachedToken && Date.now() < tokenExpiresAt) {
      console.log("🔄 Usando partner token in cache");
      return cachedToken;
    }

    console.log("🔑 Richiesta nuovo partner token...");
    const res = await axios.post(
      `${TESLA_AUTH_URL}/oauth2/v3/token`,
      new URLSearchParams({
        grant_type: "client_credentials",
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
        scope:
          "openid offline_access vehicle_device_data vehicle_state vehicle_cmds vehicle_charging_cmds"
      }),
      { headers: { "Content-Type": "application/x-www-form-urlencoded" } }
    );

    cachedToken = res.data.access_token;
    tokenExpiresAt = Date.now() + (res.data.expires_in - 60) * 1000;

    console.log("✅ Partner token ottenuto:", cachedToken.slice(0,10) + "...");
    return cachedToken;
  } catch (err) {
    console.error("❌ Errore ottenimento partner token:", err.response?.data || err.message);
    throw new Error("Failed to get partner token");
  }
}

// =====================
// Sign command
// =====================
async function signCommand(vehicleId, command) {
  try {
    console.log("✍️ Firma comando:", command, "per VIN:", vehicleId);
    const privateKeyPem = PRIVATE_KEY.replace(/\\n/g, "\n");
    const key = await importPKCS8(privateKeyPem, "ES256");

    const jwt = await new SignJWT({
      aud: AUDIENCE,
      sub: vehicleId,
      cmd: command
    })
      .setProtectedHeader({ alg: "ES256" })
      .setIssuedAt()
      .setExpirationTime("2m")
      .sign(key);

    console.log("✅ Comando firmato (JWT primi 20 char):", jwt.slice(0,20) + "...");
    return jwt;
  } catch (err) {
    console.error("❌ Errore firma comando:", err);
    throw new Error("Failed to sign command");
  }
}

// =====================
// Command endpoint
// =====================
app.post("/command/:vehicleId/:command", async (req, res) => {
  try {
    const { vehicleId, command } = req.params;
    console.log("🚀 Route /command chiamata", req.params);

    const vehicleVin = VIN;
    const partnerAccountId = ACCOUNT_ID;
    const url = `https://fleet-api.prd.eu.vn.cloud.tesla.com/api/1/vehicles/${vehicleVin}/commands/${command}`;

    console.log("VIN:", vehicleVin, "ACCOUNT_ID:", partnerAccountId, "COMMAND:", command, "URL:", url);

    // Partner token
    const token = await getPartnerToken();

    // Firma JWT
    const jwt = await signCommand(vehicleVin, command);

    // Chiamata Fleet API
    let response;
/*    try {
      response = await axios.post(
        url,
        { vin: vehicleVin, account_id: partnerAccountId },
        { headers: {
            Authorization: `Bearer ${token}`,
            "Tesla-Command-Signature": jwt,
            "Content-Type": "application/json"
          }
        }
      );
      console.log("✅ Risposta Tesla ricevuta:", JSON.stringify(response.data));
    } catch (axiosErr) {
      console.error("❌ Errore Axios verso Tesla:", axiosErr.response?.data || axiosErr.message);
      throw new Error("Tesla API call failed");
    }
*/
    // Decidi il body in base al comando
let body;
if (command === "charge_start") {
  body = {}; // per charge_start non serve body
} else {
  body = { vin: vehicleVin, account_id: partnerAccountId };
}
try {
  response = await axios.post(url, body, {
    headers: {
      Authorization: `Bearer ${token}`,
      "Tesla-Command-Signature": jwt,
      "Content-Type": "application/json"
    },
    validateStatus: () => true // per vedere anche 404/500
  });
  console.log("Axios status:", response.status, "data:", response.data);
} catch (err) {
  console.error("Axios error:", err.message);
}
    // Log finale dettagliato
    console.log("🎯 Comando inviato:");
    console.log({
      vehicleVin,
      command,
      partnerAccountId,
      token: token.slice(0,10) + "...",
      jwt: jwt.slice(0,20) + "...",
      response: response.data
    });

    res.json(response.data);

  } catch (err) {
    console.error("❌ Errore /command endpoint:", err.message);
    res.status(500).json({
      error: err.message,
      details: err.response?.data || "No additional data"
    });
  }
});

// =====================
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log("Server running on port", PORT);
});
