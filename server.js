import express from "express";
import fs from "fs";
import jwt from "jsonwebtoken";
import axios from "axios";

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 10000;

// Legge la chiave privata Tesla dal Secret File di Render
const privateKey = fs.readFileSync(process.env.PRIVATE_KEY, "utf8");

// Funzione per creare JWT ES256 per Tesla Fleet API
function createTeslaJWT(aud = "https://fleet-api.tesla.com") {
  const payload = {
    aud,
    iat: Math.floor(Date.now() / 1000)
  };
  return jwt.sign(payload, privateKey, { algorithm: "ES256", expiresIn: "5m" });
}

// Endpoint di test semplice
app.get("/", (req, res) => {
  res.send("Proxy Tesla pronto!");
});

// Endpoint demo comando
app.post("/command/:vehicleId/:command", async (req, res) => {
  const { vehicleId, command } = req.params;
  const token = createTeslaJWT();

  try {
    const response = await axios.post(
      `https://owner-api.teslamotors.com/api/1/vehicles/${vehicleId}/command/${command}`,
      {}, // payload vuoto; alcuni comandi richiedono dati
      { headers: { Authorization: `Bearer ${token}` } }
    );
    res.json(response.data);
  } catch (err) {
    console.error(err.response?.data || err.message);
    res.status(500).json({ error: "Errore invio comando" });
  }
});

app.listen(PORT, () => {
  console.log(`Server in ascolto su porta ${PORT}`);
});
