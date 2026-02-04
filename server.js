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
  VIN,
  PORT = 3000
} = process.env;

// =====================
// HOME
// =====================
app.get("/", (req, res) => {
  res.send("Greencharge Tesla Proxy OK");
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

    console.log("🔑 JWKS servito correttamente");
    res.json({ keys: [jwk] });
  } catch (err) {
    console.error("❌ Errore JWKS:", err.message);
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
    console.error("❌ Errore Tesla public key:", err.message);
    res.status(500).send("Public key not available");
  }
});

// =====================
// PARTNER TOKEN
// =====================
let cachedToken = null;
let tokenExpiresAt = 0;

async function getPartnerToken() {
  if (cachedToken && Date.now() < tokenExpiresAt) {
    console.log("🔄 Partner token da cache");
    return cachedToken;
  }

  try {
    console.log("🔑 Richiesta partner token...");
    const response = await axios.post(
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

    cachedToken = response.data.access_token;
    tokenExpiresAt =
      Date.now() + (response.data.expires_in - 60) * 1000;

    console.log("✅ Partner token ottenuto:", cachedToken.slice(0, 10) + "...");
    return cachedToken;
  } catch (err) {
    console.error(
      "❌ Errore partner token:",
      err.response?.data || err.message
    );
    throw new Error("Failed to obtain partner token");
  }
}

// =====================
// SIGN COMMAND (CORRETTO TESLA)
// =====================
async function signCommand(vehicleVin) {
  try {
    const privateKeyPem = PRIVATE_KEY.replace(/\\n/g, "\n");
    const key = await importPKCS8(privateKeyPem, "ES256");

    const jwt = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256" })
      .setIssuer(ACCOUNT_ID)
      .setSubject(vehicleVin)
      .setAudience(AUDIENCE)
      .setIssuedAt()
      .setExpirationTime("2m")
      .sign(key);

    console.log("✍️ JWT firmato:", jwt.slice(0, 20) + "...");
    return jwt;
  } catch (err) {
    console.error("❌ Errore firma JWT:", err.message);
    throw new Error("JWT signing failed");
  }
}

// =====================
// COMMAND ENDPOINT
// =====================
app.post("/command/:vehicleId/:command", async (req, res) => {
  try {
    const { command } = req.params;

    const vehicleVin = VIN;
    const url = `https://fleet-api.prd.eu.vn.cloud.tesla.com/api/1/vehicles/${vehicleVin}/commands/${command}`;

    console.log("🚀 Comando:", command);
    console.log("🔗 URL:", url);

    const token = await getPartnerToken();
    const jwt = await signCommand(vehicleVin);

    const response = await axios.post(
      url,
      {}, // BODY SEMPRE VUOTO
      {
        headers: {
          Authorization: `Bearer ${token}`,
          "Tesla-Command-Signature": jwt,
          "X-Tesla-Account-ID": ACCOUNT_ID,
          "Content-Type": "application/json"
        },
        validateStatus: () => true
      }
    );

    console.log("🟢 Tesla status:", response.status);
    console.log("🟢 Tesla response:", response.data);

    res.status(response.status).json(response.data);
  } catch (err) {
    console.error("❌ /command error:", err.message);
    res.status(500).json({ error: err.message });
  }
});

// =====================
// START SERVER
// =====================
app.listen(PORT, () => {
  console.log(`🚀 Server running on port ${PORT}`);
});
