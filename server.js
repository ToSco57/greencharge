import express from "express";
import axios from "axios";
import { SignJWT, importPKCS8, exportJWK } from "jose";


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
  TESLA_AUTH_URL
} = process.env;

// =====================
// HOME (solo per debug umano)
// =====================
app.get("/", (req, res) => {
  res.send("Greencharge Tesla Proxy OK");
});

// =====================
// JWKS (QUESTO È QUELLO CHE TESLA CONTROLLA)
// =====================
app.get("/.well-known/jwks.json", async (req, res) => {
  try {
    const privateKeyPem = PRIVATE_KEY.replace(/\\n/g, "\n");
    const key = await importPKCS8(privateKeyPem, "ES256");
    const jwk = await exportJWK(key);

    // 🔥 RIMUOVI LA PRIVATE KEY
    delete jwk.d;
    jwk.use = "sig";
    jwk.alg = "ES256";
    jwk.kid = "greencharge-key-1";

    res.json({ keys: [jwk] });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
import fs from "fs";
import path from "path";

// =====================
// TESLA PARTNER PUBLIC KEY (PEM)
// =====================
app.get(
  "/.well-known/appspecific/com.tesla.3p.public-key.pem",
  (req, res) => {
    try {
      const keyPath = path.join(
        process.cwd(),
        "keys",
        "tesla-public-key.pem"
      );

      const pem = fs.readFileSync(keyPath, "utf8");

      res.setHeader("Content-Type", "application/x-pem-file");
      res.status(200).send(pem);
    } catch (err) {
      res.status(500).send("Public key not available");
    }
  }
);
// =====================
// PARTNER TOKEN
// =====================
let cachedToken = null;
let tokenExpiresAt = 0;

async function getPartnerToken() {
  if (cachedToken && Date.now() < tokenExpiresAt) {
    return cachedToken;
  }

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

  return cachedToken;
}

// =====================
// SIGN COMMAND
// =====================
async function signCommand(vehicleId, command) {
  const privateKeyPem = PRIVATE_KEY.replace(/\\n/g, "\n");
  const key = await importPKCS8(privateKeyPem, "ES256");

  return new SignJWT({
    aud: AUDIENCE,
    sub: vehicleId,
    cmd: command
  })
    .setProtectedHeader({ alg: "ES256" })
    .setIssuedAt()
    .setExpirationTime("2m")
    .sign(key);
}

// =====================
// COMMAND ENDPOINT (aggiornato con ENV ACCOUNT_ID e VIN)
// =====================
app.post("/command/:vehicleId/:command", async (req, res) => {
  try {
    const { command } = req.params;

    // Legge VIN e ACCOUNT_ID dalle variabili d'ambiente
    const vehicleVin = process.env.VIN;
    const partnerAccountId = process.env.ACCOUNT_ID;

    if (!vehicleVin || !partnerAccountId) {
      return res.status(500).json({
        error: "VIN or ACCOUNT_ID not set in environment variables"
      });
    }

    // 1️⃣ Ottieni partner token
    const token = await getPartnerToken();

    // 2️⃣ Firma JWT ES256
    const jwt = await signCommand(vehicleVin, command);

    // 3️⃣ Chiamata Fleet API con body corretto
    const response = await axios.post(
      `https://fleet-api.prd.eu.vn.cloud.tesla.com/api/1/vehicles/${vehicleVin}/command/${command}`,
      {
        vin: vehicleVin,
        account_id: partnerAccountId
      },
      {
        headers: {
          Authorization: `Bearer ${token}`,
          "Tesla-Command-Signature": jwt
        }
      }
    );

    res.json(response.data);
  } catch (err) {
    res.status(500).json({
      error: err.message,
      details: err.response?.data
    });
  }
});

// =====================
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log("Server running on port", PORT);
});
