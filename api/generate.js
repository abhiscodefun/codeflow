import { GoogleGenerativeAI } from "@google/generative-ai";

export default async function handler(req, res) {
  // Add CORS headers so Flutter web can successfully make requests to this backend
  res.setHeader('Access-Control-Allow-Credentials', true)
  res.setHeader('Access-Control-Allow-Origin', '*') 
  res.setHeader('Access-Control-Allow-Methods', 'GET,OPTIONS,PATCH,DELETE,POST,PUT')
  res.setHeader(
    'Access-Control-Allow-Headers',
    'X-CSRF-Token, X-Requested-With, Accept, Accept-Version, Content-Length, Content-MD5, Content-Type, Date, X-Api-Version'
  )

  // Handle preflight requests
  if (req.method === 'OPTIONS') {
    res.status(200).end()
    return
  }
  
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Method Not Allowed" });
  }

  try {
    const apiKey = process.env.GEMINI_API_KEY;
    if (!apiKey) {
      console.error("API Key not found!");
      return res.status(500).json({ error: "API Key not configured." });
    }

    const genAI = new GoogleGenerativeAI(apiKey);
    const { promptText, base64Image, isInitialGeneration } = req.body;

    const model = genAI.getGenerativeModel({ model: 'gemini-2.5-flash' });

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

    return res.status(200).json({ text: responseText });
  } catch (error) {
    console.error("Gemini API Error:", error);
    return res.status(500).json({ error: error.message });
  }
}
