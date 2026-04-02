require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { GoogleGenerativeAI } = require('@google/generative-ai');

const app = express();
app.use(cors());
// Parse large payloads for images
app.use(express.json({ limit: '50mb' }));

const port = process.env.PORT || 3000;

// Set up Gemini SDK
// The user should place their GEMINI_API_KEY in the .env file.
const apiKey = process.env.GEMINI_API_KEY;
const genAI = new GoogleGenerativeAI(apiKey);

app.post('/api/generate', async (req, res) => {
  if (!apiKey) {
    return res.status(500).json({ error: "GEMINI_API_KEY is not configured on the backend." });
  }

  try {
    const { promptText, base64Image, isInitialGeneration } = req.body;

    const model = genAI.getGenerativeModel({ model: 'gemini-2.5-flash' });

    // Construct the payload as per original Flutter logic
    const parts = [
      { text: promptText }
    ];

    if (base64Image) {
      parts.push({
        inlineData: {
          data: base64Image,
          mimeType: 'image/png'
        }
      });
    }

    const result = await model.generateContent(parts);
    const responseText = result.response.text();

    res.json({ text: responseText });
  } catch (error) {
    console.error("Gemini API Error:", error);
    res.status(500).json({ error: error.message });
  }
});

app.listen(port, () => {
  console.log(`Secure backend listening at http://localhost:${port}`);
});
