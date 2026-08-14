const express = require("express");
const cors = require("cors");

const app = express();

app.use(cors());
app.use(express.json());

app.get("/", (req, res) => {
    res.send("ChatBot Backend is running!");
});

app.post("/api/login", (req, res) => {
    const { email, password } = req.body;

    console.log("Login request received");
    console.log("Email:", email);

    res.json({
        success: true,
        message: "Login successful"
    });
});

app.listen(3000, () => {
    console.log("Backend running on http://localhost:3000");
});