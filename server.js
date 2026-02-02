import express from "express";
import axios from "axios";
import { SignJWT, importPKCS8 } from "jose";

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
      scope: "openid offline_access vehicle_device_data vehicle_state vehicle_cmds vehicle_charging_cmds"
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
  const key = await importPKCS8(PRIVATE_KEY, "ES256");

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
// ENDPOINT
// =====================
app.post("/command/:vehicleId/:command", async (req, res) => {
  try {
    const { vehicleId, command } = req.params;

    const token = await getPartnerToken();
    const jwt = await signCommand(vehicleId, command);

    const response = await axios.post(
      `https://fleet-api.prd.eu.vn.cloud.tesla.com/api/1/vehicles/${vehicleId}/command/${command}`,
      {},
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
