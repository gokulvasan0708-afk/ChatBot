const express = require("express");
const cors = require("cors");

const {
    initializeApp,
    cert,
} = require("firebase-admin/app");

const {
    getMessaging,
} = require("firebase-admin/messaging");

const {
    getFirestore,
} = require("firebase-admin/firestore");

const serviceAccount = require("./serviceAccountKey.json");

// ==========================================================
// FIREBASE ADMIN INITIALIZE
// ==========================================================

initializeApp({
    credential: cert(serviceAccount),
});

const db = getFirestore();
const messaging = getMessaging();

// ==========================================================
// EXPRESS
// ==========================================================

const app = express();

app.use(cors());
app.use(express.json());

// ==========================================================
// TEST
// ==========================================================

app.get("/", (req, res) => {
    res.json({
        success: true,
        message: "ChatBot Backend + FCM is running!",
    });
});

// ==========================================================
// LOGIN TEST
// ==========================================================

app.post("/api/login", (req, res) => {
    const { email, password } = req.body;

    console.log("Login request received");
    console.log("Email:", email);

    res.json({
        success: true,
        message: "Login successful",
    });
});

// ==========================================================
// SEND CHAT NOTIFICATION
// ==========================================================

app.post("/api/send-notification", async (req, res) => {
    try {
        const {
            receiverUid,
            senderUid,
            senderName,
            message,
        } = req.body;

        // ------------------------------------------------------
        // CHECK DATA
        // ------------------------------------------------------

        if (!receiverUid) {
            return res.status(400).json({
                success: false,
                message: "receiverUid is required",
            });
        }

        if (!senderName) {
            return res.status(400).json({
                success: false,
                message: "senderName is required",
            });
        }

        if (!message) {
            return res.status(400).json({
                success: false,
                message: "message is required",
            });
        }

        // ------------------------------------------------------
        // GET RECEIVER USER DOCUMENT
        // ------------------------------------------------------

        const userDoc = await db
            .collection("users")
            .doc(receiverUid)
            .get();

        if (!userDoc.exists) {
            return res.status(404).json({
                success: false,
                message: "Receiver user not found",
            });
        }

        const userData = userDoc.data();

        const fcmToken = userData?.fcmToken;

        // ------------------------------------------------------
        // CHECK FCM TOKEN
        // ------------------------------------------------------

        if (!fcmToken) {
            console.log(
                "No FCM token for user:",
                receiverUid
            );

            return res.status(404).json({
                success: false,
                message: "Receiver has no FCM token",
            });
        }

        console.log(
            "Sending notification to:",
            receiverUid
        );

        // ------------------------------------------------------
        // FCM MESSAGE
        // ------------------------------------------------------

        const fcmMessage = {
            token: fcmToken,

            notification: {
                title: senderName,
                body: message,
            },

            data: {
                type: "chat",
                senderUid: senderUid ?? "",
            },

            android: {
                priority: "high",
                notification: {
                    channelId: "chat_messages",
                    sound: "default",
                },
            },
        };

        // ------------------------------------------------------
        // SEND FCM
        // ------------------------------------------------------

        const response = await messaging.send(fcmMessage);

        console.log(
            "Notification sent successfully:",
            response
        );

        return res.json({
            success: true,
            message: "Notification sent",
            response: response,
        });

    } catch (error) {

        console.error(
            "FCM notification error:",
            error
        );

        return res.status(500).json({
            success: false,
            message: "Failed to send notification",
            error: error.message,
        });
    }
});

// ==========================================================
// START SERVER
// ==========================================================

app.listen(3000, () => {
    console.log(
        "Backend running on http://localhost:3000"
    );
});