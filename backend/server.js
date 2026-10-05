const express = require("express");
const cors = require("cors");
const crypto = require("crypto");

// Node 20+ can load a local .env file without an extra dependency.
try {
    process.loadEnvFile();
} catch (_) {
    // Environment variables may already be provided by the host.
}

const {
    initializeApp,
    cert,
} = require("firebase-admin/app");

const {
    getMessaging,
} = require("firebase-admin/messaging");

const {
    getFirestore,
    FieldValue,
} = require("firebase-admin/firestore");

const {
    getAuth,
} = require("firebase-admin/auth");

const serviceAccount = require("./serviceAccountKey.json");

// ==========================================================
// FIREBASE ADMIN INITIALIZE
// ==========================================================

initializeApp({
    credential: cert(serviceAccount),
});

const db = getFirestore();
const messaging = getMessaging();
const auth = getAuth();

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
        message: "chatbot Backend + FCM is running!",
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
// DELETE ACCOUNT
// ACCOUNT SWITCHING MENU -> "Delete Account"
// ==========================================================

app.post("/api/delete-account", async (req, res) => {
    try {
        const { uid } = req.body;

        if (!uid) {
            return res.status(400).json({
                success: false,
                message: "uid is required",
            });
        }

        await auth.deleteUser(uid);

        await db.recursiveDelete(
            db.collection("users").doc(uid)
        );

        const linkedRefs = await db
            .collectionGroup("switchAccounts")
            .where("uid", "==", uid)
            .get();

        if (!linkedRefs.empty) {
            const batch = db.batch();

            linkedRefs.docs.forEach(doc => {
                batch.delete(doc.ref);
            });

            await batch.commit();
        }

        console.log(
            "Account permanently deleted:",
            uid
        );

        return res.json({
            success: true,
            message: "Account permanently deleted",
        });

    } catch (error) {

        console.error(
            "Delete account error:",
            error
        );

        if (error.code === "auth/user-not-found") {
            return res.status(404).json({
                success: false,
                message: "Account not found",
            });
        }

        return res.status(500).json({
            success: false,
            message: "Failed to delete account",
            error: error.message,
        });
    }
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

        const relationshipSettings = await db
            .collection("users")
            .doc(receiverUid)
            .collection("chatSettings")
            .doc(senderUid || "")
            .get();

        const relationshipData =
            relationshipSettings.exists
                ? relationshipSettings.data()
                : {};

        if (relationshipData?.blocked === true) {
            return res.json({
                success: true,
                muted: true,
                blocked: true,
                message: "Message notification suppressed",
            });
        }

        if (relationshipData?.muted === true) {
            return res.json({
                success: true,
                muted: true,
                message: "Message notification muted",
            });
        }

        const fcmToken = userData?.fcmToken;

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
                    icon: "ic_stat_nexus",
                },
            },
        };

        const response =
            await messaging.send(fcmMessage);

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
// SEND CONNECT RESPONSE NOTIFICATION
// ==========================================================

app.post("/api/send-connect-response", async (req, res) => {
    try {
        const {
            receiverUid,
            senderUid,
            senderName,
            response,
        } = req.body;

        if (!receiverUid) {
            return res.status(400).json({
                success: false,
                message: "receiverUid is required",
            });
        }

        if (!senderUid) {
            return res.status(400).json({
                success: false,
                message: "senderUid is required",
            });
        }

        if (!response) {
            return res.status(400).json({
                success: false,
                message: "response is required",
            });
        }

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

        if (!fcmToken) {
            return res.status(404).json({
                success: false,
                message: "Receiver has no FCM token",
            });
        }

        let title = "";
        let body = "";

        if (response === "accepted") {
            title = "Connection Accepted";
            body =
                `${senderName} accepted your connection request`;
        } else if (response === "declined") {
            title = "Connection Request Declined";
            body =
                `${senderName} declined your connection request`;
        } else {
            return res.status(400).json({
                success: false,
                message: "Invalid response",
            });
        }

        const fcmMessage = {
            token: fcmToken,

            notification: {
                title: title,
                body: body,
            },

            data: {
                type: "connect_response",
                senderUid: senderUid,
                response: response,
            },

            android: {
                priority: "high",

                notification: {
                    channelId: "chat_messages",
                    sound: "default",
                    icon: "ic_stat_nexus",
                },
            },
        };

        const result =
            await messaging.send(fcmMessage);

        console.log(
            "Connect response notification sent:",
            result
        );

        return res.json({
            success: true,
            message:
                "Connect response notification sent",
        });

    } catch (error) {

        console.error(
            "Connect response error:",
            error
        );

        return res.status(500).json({
            success: false,
            message:
                "Failed to send response notification",
            error: error.message,
        });
    }
});

// ==========================================================
// SEND CONNECTION REQUEST NOTIFICATION
// ==========================================================

app.post("/api/send-connection-notification", async (req, res) => {
    try {
        const {
            receiverUid,
            senderUid,
            senderName,
        } = req.body;

        if (!receiverUid) {
            return res.status(400).json({
                success: false,
                message: "receiverUid is required",
            });
        }

        if (!senderUid) {
            return res.status(400).json({
                success: false,
                message: "senderUid is required",
            });
        }

        if (!senderName) {
            return res.status(400).json({
                success: false,
                message: "senderName is required",
            });
        }

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

        if (!fcmToken) {
            return res.status(404).json({
                success: false,
                message: "Receiver has no FCM token",
            });
        }

        console.log(
            "Sending connection request notification to:",
            receiverUid
        );

        const fcmMessage = {
            token: fcmToken,

            notification: {
                title: "New Connection Request",
                body:
                    `${senderName} sent you a connection request`,
            },

            data: {
                type: "connection_request",
                senderUid: senderUid,
            },

            android: {
                priority: "high",

                notification: {
                    channelId: "chat_messages",
                    sound: "default",
                    icon: "ic_stat_nexus",
                },
            },
        };

        const response =
            await messaging.send(fcmMessage);

        console.log(
            "Connection notification sent:",
            response
        );

        return res.json({
            success: true,
            message: "Connection notification sent",
        });

    } catch (error) {

        console.error(
            "Connection notification error:",
            error
        );

        return res.status(500).json({
            success: false,
            message:
                "Failed to send connection notification",
            error: error.message,
        });
    }
});

// ==========================================================
// CONNECTION RESPONSE
// ACCEPT / DECLINE
// ==========================================================

app.post("/api/connection-response", async (req, res) => {
    try {
        const {
            receiverUid,
            senderUid,
            senderName,
            action,
        } = req.body;

        if (!receiverUid) {
            return res.status(400).json({
                success: false,
                message: "receiverUid is required",
            });
        }

        if (!senderUid) {
            return res.status(400).json({
                success: false,
                message: "senderUid is required",
            });
        }

        if (!action) {
            return res.status(400).json({
                success: false,
                message: "action is required",
            });
        }

        if (
            action !== "accepted" &&
            action !== "declined"
        ) {
            return res.status(400).json({
                success: false,
                message:
                    "action must be accepted or declined",
            });
        }

        const senderDoc = await db
            .collection("users")
            .doc(senderUid)
            .get();

        if (!senderDoc.exists) {
            return res.status(404).json({
                success: false,
                message: "Sender user not found",
            });
        }

        const senderData = senderDoc.data();

        const receiverDoc = await db
            .collection("users")
            .doc(receiverUid)
            .get();

        const receiverData = receiverDoc.exists
            ? receiverDoc.data()
            : {};

        const acceptedDisplayName =
            action === "accepted"
                ? (
                    receiverData?.privateName ||
                    senderName
                )
                : senderName;

        const fcmToken =
            senderData?.fcmToken;

        // ------------------------------------------------------
        // ACCEPT
        // ------------------------------------------------------

        if (action === "accepted") {

            const connectionUsers = [
                senderUid,
                receiverUid,
            ].sort();

            const connectionId =
                connectionUsers.join("_");

            await db
                .collection("connections")
                .doc(connectionId)
                .set({
                    users: connectionUsers,
                    status: "connected",
                    createdAt: new Date(),
                });

            console.log(
                "Connection created:",
                connectionId
            );
        }

        // ------------------------------------------------------
        // PERSIST RESPONSE NOTIFICATION
        // ------------------------------------------------------

        await db
            .collection("notifications")
            .add({
                receiverUid: senderUid,
                senderUid: receiverUid,
                senderName: acceptedDisplayName,

                message:
                    action === "accepted"
                        ? `${acceptedDisplayName} accepted your connection request`
                        : `${senderName} declined your connection request`,

                type:
                    action === "accepted"
                        ? "connection_accepted"
                        : "connection_declined",

                createdAt: new Date(),

                expiresAt:
                    new Date(
                        Date.now() +
                        7 * 24 * 60 * 60 * 1000
                    ),
            });

        // ------------------------------------------------------
        // SEND RESPONSE NOTIFICATION
        // ------------------------------------------------------

        if (fcmToken) {

            const notificationTitle =
                action === "accepted"
                    ? "Connection Accepted"
                    : "Connection Request Declined";

            const notificationBody =
                action === "accepted"
                    ? `${acceptedDisplayName} accepted your connection request`
                    : `${senderName} declined your connection request`;

            const fcmMessage = {

                token: fcmToken,

                notification: {
                    title: notificationTitle,
                    body: notificationBody,
                },

                data: {
                    type:
                        action === "accepted"
                            ? "connection_accepted"
                            : "connection_declined",

                    senderUid:
                        receiverUid,
                },

                android: {
                    priority: "high",

                    notification: {
                        channelId: "chat_messages",
                        sound: "default",
                        icon: "ic_stat_nexus",
                    },
                },
            };

            const response =
                await messaging.send(
                    fcmMessage
                );

            console.log(
                "Response notification sent:",
                response
            );
        }

        return res.json({
            success: true,
            message:
                action === "accepted"
                    ? "Connection accepted"
                    : "Connection declined",
        });

    } catch (error) {

        console.error(
            "Connection response error:",
            error
        );

        return res.status(500).json({
            success: false,
            message:
                "Failed to process connection response",
            error: error.message,
        });
    }
});

// ==========================================================
// CLOUDINARY VOICE ASSET DELETE
// ==========================================================
// Flutter never receives the Cloudinary API secret.
// Flutter sends:
//   - Firebase ID token
//   - chatId
//   - messageId
//   - Cloudinary publicId
//
// Backend verifies the caller and message before deleting.
// ==========================================================

app.post("/api/cloudinary/delete-audio", async (req, res) => {
    try {

        const authorization =
            req.headers.authorization || "";

        const token =
            authorization.startsWith("Bearer ")
                ? authorization
                    .substring(7)
                    .trim()
                : "";

        if (!token) {
            return res.status(401).json({
                success: false,
                message:
                    "Firebase ID token is required",
            });
        }

        const decodedToken =
            await auth.verifyIdToken(token);

        const callerUid =
            decodedToken.uid;

        const {
            chatId,
            messageId,
            publicId,
        } = req.body || {};

        if (
            !chatId ||
            !messageId ||
            !publicId
        ) {
            return res.status(400).json({
                success: false,
                message:
                    "chatId, messageId and publicId are required",
            });
        }

        // ------------------------------------------------------
        // CHECK CHAT
        // ------------------------------------------------------

        const chatRef =
            db.collection("chats").doc(chatId);

        const chatSnap =
            await chatRef.get();

        if (!chatSnap.exists) {
            return res.status(404).json({
                success: false,
                message: "Chat not found",
            });
        }

        const chatData =
            chatSnap.data() || {};

        const participants =
            Array.isArray(
                chatData.participants
            )
                ? chatData.participants
                : [];

        if (!participants.includes(callerUid)) {
            return res.status(403).json({
                success: false,
                message:
                    "You are not a participant in this chat",
            });
        }

        // ------------------------------------------------------
        // GET MESSAGE
        // ------------------------------------------------------

        const messageRef =
            chatRef
                .collection("messages")
                .doc(messageId);

        const messageSnap =
            await messageRef.get();

        if (!messageSnap.exists) {
            return res.status(404).json({
                success: false,
                message:
                    "Voice message not found",
            });
        }

        const messageData =
            messageSnap.data() || {};

        // ------------------------------------------------------
        // CHECK MESSAGE PARTICIPANT
        // ------------------------------------------------------

        const messageParticipants = [
            (
                messageData.senderId ||
                ""
            ).toString(),

            (
                messageData.receiverId ||
                ""
            ).toString(),
        ];

        if (
            !messageParticipants.includes(
                callerUid
            )
        ) {
            return res.status(403).json({
                success: false,
                message:
                    "You are not allowed to delete this voice asset",
            });
        }

        // ------------------------------------------------------
        // CHECK VOICE MESSAGE
        // ------------------------------------------------------

        if (
            (
                messageData.messageType ||
                "text"
            ).toString() !== "voice"
        ) {
            return res.status(400).json({
                success: false,
                message:
                    "This message is not a voice message",
            });
        }

        // ------------------------------------------------------
        // CHECK PUBLIC ID
        // ------------------------------------------------------

        const storedPublicId =
            (
                messageData.cloudinaryPublicId ||
                ""
            ).toString();

        if (
            storedPublicId &&
            storedPublicId !==
                publicId.toString()
        ) {
            return res.status(403).json({
                success: false,
                message:
                    "Cloudinary publicId does not match the message",
            });
        }

        // ------------------------------------------------------
        // ALREADY DELETED
        // ------------------------------------------------------

        if (
            messageData.cloudinaryDeleted ===
            true
        ) {
            return res.json({
                success: true,
                message:
                    "Cloudinary asset was already deleted",
            });
        }

        // ------------------------------------------------------
        // CLOUDINARY CREDENTIALS
        // ------------------------------------------------------

        const cloudName =
            (
                process.env
                    .CLOUDINARY_CLOUD_NAME ||
                ""
            ).trim();

        const apiKey =
            (
                process.env
                    .CLOUDINARY_API_KEY ||
                ""
            ).trim();

        const apiSecret =
            (
                process.env
                    .CLOUDINARY_API_SECRET ||
                ""
            ).trim();

        if (
            !cloudName ||
            !apiKey ||
            !apiSecret
        ) {
            return res.status(500).json({
                success: false,
                message:
                    "Cloudinary backend credentials are not configured",
            });
        }

        // ------------------------------------------------------
        // CREATE CLOUDINARY SIGNATURE
        // ------------------------------------------------------

        const timestamp =
            Math.floor(
                Date.now() / 1000
            );

        const signatureBase =
            `invalidate=true&public_id=${publicId}&timestamp=${timestamp}${apiSecret}`;

        const signature =
            crypto
                .createHash("sha1")
                .update(signatureBase)
                .digest("hex");

        // ------------------------------------------------------
        // CLOUDINARY DESTROY REQUEST
        // Audio is uploaded as video resource type.
        // ------------------------------------------------------

        const body =
            new URLSearchParams({
                public_id:
                    publicId.toString(),

                timestamp:
                    String(timestamp),

                api_key:
                    apiKey,

                signature:
                    signature,

                invalidate:
                    "true",
            });

        const cloudinaryResponse =
            await fetch(
                `https://api.cloudinary.com/v1_1/${encodeURIComponent(cloudName)}/video/destroy`,
                {
                    method: "POST",

                    headers: {
                        "Content-Type":
                            "application/x-www-form-urlencoded",
                    },

                    body,
                }
            );

        const cloudinaryData =
            await cloudinaryResponse.json();

        if (
            !cloudinaryResponse.ok ||
            ![
                "ok",
                "not found",
            ].includes(
                (
                    cloudinaryData.result ||
                    ""
                ).toString()
            )
        ) {

            console.error(
                "Cloudinary destroy failed:",
                cloudinaryData
            );

            return res.status(502).json({
                success: false,
                message:
                    "Cloudinary asset deletion failed",
                cloudinary:
                    cloudinaryData,
            });
        }

        // ------------------------------------------------------
        // MARK CLOUDINARY AS DELETED
        // ------------------------------------------------------

        await messageRef.update({
            cloudinaryDeleted:
                true,

            cloudinaryDeletedAt:
                new Date(),
        });

        return res.json({
            success: true,
            message:
                "Cloudinary voice asset deleted",

            result:
                cloudinaryData.result ||
                "ok",
        });

    } catch (error) {

        console.error(
            "Cloudinary voice delete error:",
            error
        );

        if (
            error.code ===
                "auth/id-token-expired" ||

            error.code ===
                "auth/argument-error" ||

            error.code ===
                "auth/invalid-id-token"
        ) {
            return res.status(401).json({
                success: false,
                message:
                    "Invalid or expired Firebase ID token",
            });
        }

        return res.status(500).json({
            success: false,
            message:
                "Failed to delete Cloudinary voice asset",
            error:
                error.message,
        });
    }
});

// ==========================================================
// CREATE GROUP
// HUBS PAGE -> GROUPS TAB -> "Create Group"
// ----------------------------------------------------------------
// Group creation is done here (not written directly to Firestore
// from the Flutter client like chats/connections are) for one
// reason only: the group password. It must never be stored in
// plain text, and hashing has to happen somewhere the client can't
// tamper with -- this endpoint is that place, using the same
// Admin SDK `db` and the `crypto` module already required at the
// top of this file.
//
// The Group ID shown live in the Create Group dialog as the user
// types the group name (format "@(groupName)-(first 4 chars of the
// creator's Account ID)") is computed client-side purely for
// preview -- groupstab.dart recomputes it locally on every
// keystroke. The client sends that same computed value here as
// `groupId`, and this endpoint is the one place that actually
// enforces it is unique before the group is created.
// ==========================================================

app.post("/api/create-group", async (req, res) => {
    try {
        const {
            groupId,
            groupName,
            groupProfileImage,
            adminUid,
            adminAccountId,
            members,
            password,
        } = req.body;

        // ------------------------------------------------------
        // REQUIRED FIELDS
        // ------------------------------------------------------

        if (!groupId || !groupId.toString().trim()) {
            return res.status(400).json({
                success: false,
                message: "groupId is required",
            });
        }

        if (!groupName || !groupName.toString().trim()) {
            return res.status(400).json({
                success: false,
                message: "groupName is required",
            });
        }

        if (!adminUid) {
            return res.status(400).json({
                success: false,
                message: "adminUid is required",
            });
        }

        if (!password) {
            return res.status(400).json({
                success: false,
                message: "password is required",
            });
        }

        // ------------------------------------------------------
        // PASSWORD FORMAT
        // Exactly 6 characters. Digits and special/punctuation
        // characters only -- no letters, no whitespace.
        // ------------------------------------------------------

        const passwordPattern =
            /^[0-9!@#$%^&*()\-_=+\[\]{};:'",.<>/?\\|`~]{6}$/;

        if (!passwordPattern.test(password.toString())) {
            return res.status(400).json({
                success: false,
                message:
                    "Password must be exactly 6 characters, using only numbers and special characters",
            });
        }

        const cleanGroupId = groupId.toString().trim();
        const cleanGroupName = groupName.toString().trim();

        const cleanMembers = Array.isArray(members)
            ? [...new Set(
                members
                    .map((uid) => (uid || "").toString().trim())
                    .filter((uid) => uid && uid !== adminUid)
            )]
            : [];

        // ------------------------------------------------------
        // GROUP ID MUST BE UNIQUE
        // ------------------------------------------------------

        const existingGroup = await db
            .collection("groups")
            .where("groupId", "==", cleanGroupId)
            .limit(1)
            .get();

        if (!existingGroup.empty) {
            return res.status(409).json({
                success: false,
                message:
                    "That Group ID is already taken. Try a different group name.",
            });
        }

        // ------------------------------------------------------
        // HASH PASSWORD (random salt + SHA-256)
        // ------------------------------------------------------

        const passwordSalt = crypto
            .randomBytes(16)
            .toString("hex");

        const passwordHash = crypto
            .createHash("sha256")
            .update(password.toString() + passwordSalt)
            .digest("hex");

        // ------------------------------------------------------
        // CREATE GROUP DOCUMENT
        // ------------------------------------------------------

        const groupRef = db.collection("groups").doc();

        await groupRef.set({
            groupId: cleanGroupId,
            groupName: cleanGroupName,
            groupProfileImage: (groupProfileImage || "").toString(),

            adminUid: adminUid,
            adminAccountId: (adminAccountId || "").toString(),

            members: [adminUid],
            pendingMembers: cleanMembers,
            membersCount: 1,

            passwordHash: passwordHash,
            passwordSalt: passwordSalt,

            createdAt: FieldValue.serverTimestamp(),
        });

        console.log(
            "Group created:",
            cleanGroupId,
            groupRef.id
        );

        return res.json({
            success: true,
            message: "Group created",
            docId: groupRef.id,
            groupId: cleanGroupId,
            pendingMembers: cleanMembers,
        });

    } catch (error) {

        console.error(
            "Create group error:",
            error
        );

        return res.status(500).json({
            success: false,
            message: "Failed to create group",
            error: error.message,
        });
    }
});

// ==========================================================
// JOIN GROUP
// HUBS PAGE -> GROUPS TAB -> "Join Group"
// ----------------------------------------------------------------
// Joins an existing group by Group ID + Group Password. Like
// /api/create-group above, this has to go through the backend
// rather than a direct Firestore write, because checking the
// password requires reading passwordHash/passwordSalt -- fields the
// Flutter client never has access to. The client only ever learns
// whether the attempt succeeded, not either field's value.
// ==========================================================

app.post("/api/join-group", async (req, res) => {
    try {
        const { groupId, password, uid } = req.body;

        // ------------------------------------------------------
        // REQUIRED FIELDS
        // ------------------------------------------------------

        if (!groupId || !groupId.toString().trim()) {
            return res.status(400).json({
                success: false,
                message: "groupId is required",
            });
        }

        if (!password || !password.toString()) {
            return res.status(400).json({
                success: false,
                message: "password is required",
            });
        }

        if (!uid) {
            return res.status(400).json({
                success: false,
                message: "uid is required",
            });
        }

        const cleanGroupId = groupId.toString().trim();

        // ------------------------------------------------------
        // GROUP MUST EXIST (wrong Group ID -> error)
        // ------------------------------------------------------

        const groupQuery = await db
            .collection("groups")
            .where("groupId", "==", cleanGroupId)
            .limit(1)
            .get();

        if (groupQuery.empty) {
            return res.status(404).json({
                success: false,
                message: "No group found with that Group ID",
            });
        }

        const groupDoc = groupQuery.docs[0];
        const groupData = groupDoc.data() || {};

        // ------------------------------------------------------
        // PASSWORD MUST MATCH (wrong password -> error)
        // ------------------------------------------------------

        const passwordSalt = (groupData.passwordSalt || "").toString();
        const passwordHash = (groupData.passwordHash || "").toString();

        const attemptHash = crypto
            .createHash("sha256")
            .update(password.toString() + passwordSalt)
            .digest("hex");

        if (!passwordSalt || !passwordHash || attemptHash !== passwordHash) {
            return res.status(401).json({
                success: false,
                message: "Incorrect group password",
            });
        }

        // ------------------------------------------------------
        // ALREADY A MEMBER -> "already joined" message,
        // no duplicate membership created.
        // ------------------------------------------------------

        const members = Array.isArray(groupData.members)
            ? groupData.members
            : [];

        const groupName = (groupData.groupName || "").toString();
        const groupProfileImage = (groupData.groupProfileImage || "").toString();
        const adminUid = (groupData.adminUid || "").toString();

        if (members.includes(uid)) {
            return res.json({
                success: false,
                alreadyMember: true,
                message: "You're already a member of this group",
                docId: groupDoc.id,
                groupId: cleanGroupId,
                groupName,
            });
        }

        // ------------------------------------------------------
        // ADD TO MEMBERS
        // ------------------------------------------------------

        await groupDoc.ref.update({
            members: FieldValue.arrayUnion(uid),
            membersCount: FieldValue.increment(1),
            pendingMembers: FieldValue.arrayRemove(uid),
        });

        console.log(
            "User joined group:",
            cleanGroupId,
            uid
        );

        return res.json({
            success: true,
            message: "Joined group",
            docId: groupDoc.id,
            groupId: cleanGroupId,
            groupName,
            groupProfileImage,
            adminUid,
        });

    } catch (error) {

        console.error(
            "Join group error:",
            error
        );

        return res.status(500).json({
            success: false,
            message: "Failed to join group",
            error: error.message,
        });
    }
});

// ==========================================================
// AUTOMATIC RETENTION / EXPIRY CLEANUP
// ==========================================================

async function cleanupExpiredData() {

    const now = new Date();

    // ------------------------------------------------------
    // DELETE EXPIRED NOTIFICATIONS
    // 7 DAYS
    // ------------------------------------------------------

    const notifications =
        await db
            .collection("notifications")
            .where(
                "expiresAt",
                "<=",
                now
            )
            .limit(300)
            .get();

    if (
        !notifications.empty
    ) {

        const batch =
            db.batch();

        notifications.docs.forEach(
            doc => {
                batch.delete(
                    doc.ref
                );
            }
        );

        await batch.commit();
    }

    // ------------------------------------------------------
    // GET EXPIRED MESSAGES
    // ------------------------------------------------------

    const expired =
        await db
            .collectionGroup("messages")
            .where(
                "expiresAt",
                "<=",
                now
            )
            .limit(300)
            .get();

    // ------------------------------------------------------
    // PROCESS EACH MESSAGE
    // ------------------------------------------------------

    for (
        const doc of expired.docs
    ) {

        const data =
            doc.data() || {};

        // --------------------------------------------------
        // VOICE MESSAGE
        // --------------------------------------------------

        if (
            (
                data.messageType ||
                "text"
            ).toString() ===
            "voice"
        ) {

            if (
                data.cloudinaryDeleted !==
                true
            ) {

                const publicId =
                    (
                        data.cloudinaryPublicId ||
                        ""
                    )
                    .toString()
                    .trim();

                const cloudName =
                    (
                        process.env
                            .CLOUDINARY_CLOUD_NAME ||
                        ""
                    ).trim();

                const apiKey =
                    (
                        process.env
                            .CLOUDINARY_API_KEY ||
                        ""
                    ).trim();

                const apiSecret =
                    (
                        process.env
                            .CLOUDINARY_API_SECRET ||
                        ""
                    ).trim();

                if (
                    publicId &&
                    cloudName &&
                    apiKey &&
                    apiSecret
                ) {

                    try {

                        const timestamp =
                            Math.floor(
                                Date.now() /
                                1000
                            );

                        const signatureBase =
                            `invalidate=true&public_id=${publicId}&timestamp=${timestamp}${apiSecret}`;

                        const signature =
                            crypto
                                .createHash(
                                    "sha1"
                                )
                                .update(
                                    signatureBase
                                )
                                .digest(
                                    "hex"
                                );

                        const body =
                            new URLSearchParams({
                                public_id:
                                    publicId,

                                timestamp:
                                    String(
                                        timestamp
                                    ),

                                api_key:
                                    apiKey,

                                signature:
                                    signature,

                                invalidate:
                                    "true",
                            });

                        const response =
                            await fetch(
                                `https://api.cloudinary.com/v1_1/${encodeURIComponent(cloudName)}/video/destroy`,
                                {
                                    method:
                                        "POST",

                                    headers: {
                                        "Content-Type":
                                            "application/x-www-form-urlencoded",
                                    },

                                    body,
                                }
                            );

                        const result =
                            await response.json();

                        if (
                            response.ok &&
                            [
                                "ok",
                                "not found",
                            ].includes(
                                (
                                    result.result ||
                                    ""
                                ).toString()
                            )
                        ) {

                            await doc.ref.update({
                                cloudinaryDeleted:
                                    true,

                                cloudinaryDeletedAt:
                                    now,
                            });

                            console.log(
                                "Expired voice Cloudinary asset deleted:",
                                publicId
                            );

                        } else {

                            console.error(
                                "Expired voice Cloudinary delete failed:",
                                result
                            );
                        }

                    } catch (
                        voiceError
                    ) {

                        console.error(
                            "Expired voice cleanup error:",
                            voiceError
                        );
                    }
                }
            }

            // Voice cleanup is independent
            // from normal public-message cleanup.
            continue;
        }

        // --------------------------------------------------
        // PUBLIC MESSAGE EXPIRY
        // --------------------------------------------------

        if (
            (
                data.chatTypeAtSend ||
                "public"
            ) !== "public"
        ) {
            continue;
        }

        const chatDoc =
            doc.ref.parent.parent;

        if (!chatDoc) {
            continue;
        }

        const chat =
            await chatDoc.get();

        if (!chat.exists) {
            continue;
        }

        const chatData =
            chat.data() || {};

        const participants =
            Array.isArray(
                chatData.participants
            )
                ? chatData.participants
                : [];

        const savedBy =
            Array.isArray(
                data.savedBy
            )
                ? data.savedBy
                : [];

        const hiddenFor =
            Array.isArray(
                data.hiddenFor
            )
                ? data.hiddenFor
                : [];

        const nextHidden = [
            ...new Set(
                [
                    ...hiddenFor,

                    ...participants.filter(
                        uid =>
                            !savedBy.includes(
                                uid
                            )
                    ),
                ]
            ),
        ];

        if (
            nextHidden.length
        ) {

            await doc.ref.update({
                hiddenFor:
                    nextHidden,

                expiredAt:
                    now,
            });
        }
    }
}

// ==========================================================
// RUN CLEANUP IMMEDIATELY
// ==========================================================

cleanupExpiredData()
    .catch(console.error);

// ==========================================================
// RUN CLEANUP EVERY 1 HOUR
// ==========================================================

setInterval(
    () =>
        cleanupExpiredData()
            .catch(console.error),

    60 * 60 * 1000
);

// ==========================================================
// START SERVER
// ==========================================================

app.listen(
    3000,
    "0.0.0.0",
    () => {

        console.log(
            "Backend running on http://localhost:3000"
        );
    }
);