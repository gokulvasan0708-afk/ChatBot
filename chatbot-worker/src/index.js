async function createAccessToken(serviceAccount, scope) {
  const encoder = new TextEncoder();

  function base64url(data) {
    const bytes = encoder.encode(data);

    let binary = "";

    for (const byte of bytes) {
      binary += String.fromCharCode(byte);
    }

    return btoa(binary)
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
  }

  function base64urlBytes(bytes) {
    let binary = "";

    for (const byte of bytes) {
      binary += String.fromCharCode(byte);
    }

    return btoa(binary)
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
  }

  const now = Math.floor(Date.now() / 1000);

  const header = {
    alg: "RS256",
    typ: "JWT",
  };

  const payload = {
    iss: serviceAccount.client_email,

    scope:
      scope || "https://www.googleapis.com/auth/firebase.messaging",

    aud:
      "https://oauth2.googleapis.com/token",

    iat: now,

    exp: now + 3600,
  };

  const headerEncoded =
    base64url(JSON.stringify(header));

  const payloadEncoded =
    base64url(JSON.stringify(payload));

  const unsignedToken =
    `${headerEncoded}.${payloadEncoded}`;

  const privateKeyPem =
    serviceAccount.private_key.replace(
      /\\n/g,
      "\n"
    );

  const pemContents =
    privateKeyPem
      .replace(
        "-----BEGIN PRIVATE KEY-----",
        ""
      )
      .replace(
        "-----END PRIVATE KEY-----",
        ""
      )
      .replace(/\s/g, "");

  const binaryKey =
    Uint8Array.from(
      atob(pemContents),
      (c) => c.charCodeAt(0)
    );

  const privateKey =
    await crypto.subtle.importKey(
      "pkcs8",
      binaryKey.buffer,
      {
        name: "RSASSA-PKCS1-v1_5",
        hash: "SHA-256",
      },
      false,
      ["sign"]
    );

  const signature =
    await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      privateKey,
      encoder.encode(unsignedToken)
    );

  const signatureBase64 =
    base64urlBytes(
      new Uint8Array(signature)
    );

  return `${unsignedToken}.${signatureBase64}`;
}


async function getGoogleAccessToken(serviceAccount, scope) {
  const jwt =
    await createAccessToken(serviceAccount, scope);

  const response =
    await fetch(
      "https://oauth2.googleapis.com/token",
      {
        method: "POST",

        headers: {
          "Content-Type":
            "application/x-www-form-urlencoded",
        },

        body:
          `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
      }
    );

  const data =
    await response.json();

  if (!response.ok) {
    throw new Error(
      `Google token error: ${JSON.stringify(data)}`
    );
  }

  return data.access_token;
}


// ==========================================================
// FIRESTORE REST HELPERS
// ----------------------------------------------------------
// The cron cleanup below talks to Firestore directly over its
// REST API (no firebase-admin package is available inside the
// Workers runtime), reusing the same service-account JWT flow
// already used above for FCM — just with the Datastore scope
// instead of the Messaging scope.
// ==========================================================

const FIRESTORE_SCOPE = "https://www.googleapis.com/auth/datastore";

/**
 * Runs a Firestore structuredQuery and returns the matching
 * documents (raw REST document objects — { name, fields, ... }).
 */
async function firestoreRunQuery(accessToken, projectId, structuredQuery) {
  const url =
    `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents:runQuery`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ structuredQuery }),
  });

  const data = await response.json();

  if (!response.ok) {
    throw new Error(`Firestore query error: ${JSON.stringify(data)}`);
  }

  if (!Array.isArray(data)) return [];

  return data
    .filter((entry) => entry && entry.document)
    .map((entry) => entry.document);
}

/**
 * Deletes a single Firestore document given its full resource
 * name (e.g. "projects/x/databases/(default)/documents/notifications/abc").
 */
async function firestoreDeleteDocument(accessToken, documentName) {
  const url = `https://firestore.googleapis.com/v1/${documentName}`;

  const response = await fetch(url, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error(
      `Firestore delete error (${documentName}): ${JSON.stringify(data)}`
    );
  }
}

/** Reads an array field's length from a raw Firestore REST document. */
function arrayFieldLength(doc, fieldName) {
  const values = doc?.fields?.[fieldName]?.arrayValue?.values;
  return Array.isArray(values) ? values.length : 0;
}

/**
 * Creates a new document with an auto-generated ID in the given
 * collection, using the same REST API the query/delete helpers
 * above use (no firebase-admin package available in the Workers
 * runtime). `fields` must already be in Firestore's typed REST
 * format (e.g. { stringValue: "x" }, { arrayValue: { values: [...] } }).
 * Returns the raw REST document ({ name, fields, ... }).
 */
async function firestoreCreateDocument(accessToken, projectId, collectionId, fields) {
  const url =
    `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents/${collectionId}`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ fields }),
  });

  const data = await response.json();

  if (!response.ok) {
    throw new Error(`Firestore create error: ${JSON.stringify(data)}`);
  }

  return data;
}

/** Last path segment of a Firestore REST document's resource name --
 * i.e. its document ID. */
function documentIdFromName(name) {
  if (!name) return "";
  const parts = name.split("/");
  return parts[parts.length - 1];
}

/**
 * Patches specific fields on an existing Firestore document, given its
 * full resource name (e.g. "projects/x/databases/(default)/documents/groups/abc").
 * `fields` must already be in Firestore's typed REST format. `fieldPaths`
 * lists which of those fields to actually overwrite (Firestore's
 * updateMask) -- any field on the document not listed here is left
 * untouched, same as firebase-admin's `.update()`.
 */
async function firestoreUpdateDocument(accessToken, documentName, fields, fieldPaths) {
  const maskParams = fieldPaths
    .map((path) => `updateMask.fieldPaths=${encodeURIComponent(path)}`)
    .join("&");

  const url = `https://firestore.googleapis.com/v1/${documentName}?${maskParams}`;

  const response = await fetch(url, {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ fields }),
  });

  const data = await response.json();

  if (!response.ok) {
    throw new Error(`Firestore update error: ${JSON.stringify(data)}`);
  }

  return data;
}

/** Reads a string array field from a raw Firestore REST document. */
function arrayFieldStrings(doc, fieldName) {
  const values = doc?.fields?.[fieldName]?.arrayValue?.values;
  if (!Array.isArray(values)) return [];
  return values
    .map((v) => (v && typeof v.stringValue === "string" ? v.stringValue : ""))
    .filter((v) => v);
}

/** Reads a plain string field from a raw Firestore REST document. */
function stringField(doc, fieldName) {
  const value = doc?.fields?.[fieldName]?.stringValue;
  return typeof value === "string" ? value : "";
}

// ==========================================================
// PASSWORD HASHING (Web Crypto -- available in the Workers
// runtime; no `crypto` Node module / `crypto` npm package needed)
// ----------------------------------------------------------
// Used by POST /api/create-group so a group's password is never
// stored in plain text. Random 16-byte salt + SHA-256, hex encoded.
// ==========================================================

function randomHexSalt() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function hashPasswordWithSalt(password, salt) {
  const encoder = new TextEncoder();
  const data = encoder.encode(password + salt);
  const hashBuffer = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hashBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Exactly 6 characters, digits and special/punctuation characters
 * only -- no letters, no whitespace. Mirrors the same rule enforced
 * in server.js's /api/create-group.
 */
const GROUP_PASSWORD_PATTERN =
  /^[0-9!@#$%^&*()\-_=+\[\]{};:'",.<>/?\\|`~]{6}$/;

// ==========================================================
// CLEANUP JOBS
// ==========================================================

const CLEANUP_BATCH_LIMIT = 300;

/**
 * Deletes "notifications" documents whose expiresAt has passed.
 * These are the connection-accepted / connection-declined records
 * written by the app with a 7-day expiresAt (see chat_screen.dart /
 * notification.dart) — e.g. arrives Day 2, removed Day 8.
 */
async function cleanupExpiredNotifications(accessToken, projectId) {
  const nowIso = new Date().toISOString();

  const structuredQuery = {
    from: [{ collectionId: "notifications" }],
    where: {
      fieldFilter: {
        field: { fieldPath: "expiresAt" },
        op: "LESS_THAN",
        value: { timestampValue: nowIso },
      },
    },
    limit: CLEANUP_BATCH_LIMIT,
  };

  const docs = await firestoreRunQuery(accessToken, projectId, structuredQuery);

  let deleted = 0;

  for (const doc of docs) {
    try {
      await firestoreDeleteDocument(accessToken, doc.name);
      deleted += 1;
    } catch (e) {
      console.error("Failed to delete expired notification:", e.message);
    }
  }

  console.log(`Notification cleanup: deleted ${deleted}/${docs.length} expired doc(s).`);
  return deleted;
}

/**
 * Deletes "public" chat messages (chats/{chatId}/messages/{id}) whose
 * 24-hour expiresAt has passed AND that nobody has saved.
 *
 * - Private/connected messages never get an expiresAt (it's written
 *   as null at send time), so the "<" timestamp filter never matches
 *   them — they're naturally excluded and kept permanently.
 * - A message saved by either the sender or the receiver (savedBy
 *   non-empty) is left alone entirely. The client already hides an
 *   expired-but-unsaved message from anyone who *didn't* save it
 *   (see the `messages` filter in chat_screen.dart), so the saver's
 *   copy keeps showing correctly without any extra per-user field —
 *   the only thing left to do here is the actual storage cleanup for
 *   messages nobody asked to keep.
 */
async function cleanupExpiredPublicMessages(accessToken, projectId) {
  const nowIso = new Date().toISOString();

  const structuredQuery = {
    from: [{ collectionId: "messages", allDescendants: true }],
    where: {
      compositeFilter: {
        op: "AND",
        filters: [
          {
            fieldFilter: {
              field: { fieldPath: "chatTypeAtSend" },
              op: "EQUAL",
              value: { stringValue: "public" },
            },
          },
          {
            fieldFilter: {
              field: { fieldPath: "expiresAt" },
              op: "LESS_THAN",
              value: { timestampValue: nowIso },
            },
          },
        ],
      },
    },
    limit: CLEANUP_BATCH_LIMIT,
  };

  const docs = await firestoreRunQuery(accessToken, projectId, structuredQuery);

  let deleted = 0;
  let keptSaved = 0;

  for (const doc of docs) {
    if (arrayFieldLength(doc, "savedBy") > 0) {
      keptSaved += 1;
      continue;
    }

    try {
      await firestoreDeleteDocument(accessToken, doc.name);
      deleted += 1;
    } catch (e) {
      console.error("Failed to delete expired public message:", e.message);
    }
  }

  console.log(
    `Public message cleanup: deleted ${deleted}, kept ${keptSaved} saved, ` +
      `of ${docs.length} expired doc(s) found.`
  );
  return deleted;
}

/**
 * Entry point for the every-15-minutes cron trigger (see
 * wrangler.jsonc "triggers.crons"). Reuses the same
 * FIREBASE_SERVICE_ACCOUNT secret already configured for FCM,
 * just requesting a Firestore ("datastore") scoped token instead
 * of a Messaging scoped one.
 */
async function runScheduledCleanup(env) {
  try {
    if (!env.FIREBASE_SERVICE_ACCOUNT) {
      console.error(
        "Scheduled cleanup skipped: FIREBASE_SERVICE_ACCOUNT secret is missing"
      );
      return;
    }

    const serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
    const projectId = serviceAccount.project_id;

    const accessToken = await getGoogleAccessToken(
      serviceAccount,
      FIRESTORE_SCOPE
    );

    const results = await Promise.allSettled([
      cleanupExpiredNotifications(accessToken, projectId),
      cleanupExpiredPublicMessages(accessToken, projectId),
    ]);

    for (const result of results) {
      if (result.status === "rejected") {
        console.error("Cleanup job failed:", result.reason);
      }
    }

    console.log("Scheduled cleanup finished.");
  } catch (e) {
    console.error("Scheduled cleanup error:", e.message);
  }
}

// ==========================================================
// WORKER
// ==========================================================

export default {

  // ========================================================
  // CRON
  // ========================================================

  async scheduled(event, env, ctx) {

    console.log(
      "Scheduled cleanup triggered"
    );

    ctx.waitUntil(runScheduledCleanup(env));
  },


  // ========================================================
  // HTTP REQUEST
  // ========================================================

  async fetch(request, env) {

    const url =
      new URL(request.url);


    // ======================================================
    // GET /
    // ======================================================

    if (
      request.method === "GET" &&
      url.pathname === "/"
    ) {

      return new Response(
        JSON.stringify({
          success: true,
          message:
            "chatbot Notification Worker is running!",
        }),

        {
          status: 200,

          headers: {
            "Content-Type":
              "application/json",
          },
        }
      );
    }


    // ======================================================
    // POST /
    // ======================================================

    if (
      request.method === "POST" &&
      url.pathname === "/"
    ) {

      try {

        // ==================================================
        // READ BODY
        // ==================================================

        const body =
          await request.json();

        console.log(
          "Notification request:",
          body
        );


        const {
          fcmToken,
          senderName,
          message,
          senderUid,
        } = body;


        // ==================================================
        // FCM TOKEN CHECK
        // ==================================================

        if (!fcmToken) {

          return new Response(
            JSON.stringify({
              success: false,

              message:
                "fcmToken is required",
            }),

            {
              status: 400,

              headers: {
                "Content-Type":
                  "application/json",
              },
            }
          );
        }


        // ==================================================
        // SENDER NAME CHECK
        // ==================================================

        if (!senderName) {

          return new Response(
            JSON.stringify({
              success: false,

              message:
                "senderName is required",
            }),

            {
              status: 400,

              headers: {
                "Content-Type":
                  "application/json",
              },
            }
          );
        }


        // ==================================================
        // MESSAGE CHECK
        // ==================================================

        if (!message) {

          return new Response(
            JSON.stringify({
              success: false,

              message:
                "message is required",
            }),

            {
              status: 400,

              headers: {
                "Content-Type":
                  "application/json",
              },
            }
          );
        }


        // ==================================================
        // FIREBASE SERVICE ACCOUNT
        // ==================================================

        if (
          !env.FIREBASE_SERVICE_ACCOUNT
        ) {

          throw new Error(
            "FIREBASE_SERVICE_ACCOUNT secret is missing"
          );
        }


        const serviceAccount =
          JSON.parse(
            env.FIREBASE_SERVICE_ACCOUNT
          );


        // ==================================================
        // GOOGLE ACCESS TOKEN
        // ==================================================

        const accessToken =
          await getGoogleAccessToken(
            serviceAccount
          );


        // ==================================================
        // FCM URL
        // ==================================================

        const fcmUrl =
          `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;


        // ==================================================
        // SEND FCM
        // ==================================================

        const fcmResponse =
          await fetch(
            fcmUrl,
            {
              method: "POST",

              headers: {
                Authorization:
                  `Bearer ${accessToken}`,

                "Content-Type":
                  "application/json",
              },

              body:
                JSON.stringify({

                  message: {

                    token: fcmToken,

                    notification: {

                      title:
                        senderName,

                      body:
                        message,
                    },


                    data: {

                      type:
                        body.type ?? "chat",

                      senderUid:
                        senderUid ?? "",

                      // Only present for type: 'call' requests (see
                      // CallService._sendCallPushNotification in the
                      // Flutter app) -- lets a background/foreground
                      // FCM handler open straight to that call's
                      // IncomingCallScreen instead of just a generic
                      // notification tap.
                      ...(body.callId
                        ? { callId: body.callId }
                        : {}),

                      // 'voice' or 'video' -- lets a background/foreground
                      // handler show the right icon/label before the
                      // IncomingCallScreen itself (which reads the call
                      // doc's own callType) even opens.
                      ...(body.callType
                        ? { callType: body.callType }
                        : {}),
                    },


                    android: {

                      priority:
                        "HIGH",

                      notification: {

                        // Calls get their own channel so they can be
                        // configured (in the Flutter app's Android
                        // notification-channel setup) with a distinct,
                        // higher-importance sound than regular chat
                        // messages, without touching the existing
                        // "chat_messages" channel/behavior at all.
                        channel_id:
                          body.type === "call"
                            ? "voice_calls"
                            : "chat_messages",

                        sound:
                          "default",

                        icon:
                          "ic_stat_nexus",
                      },
                    },
                  },
                }),
            }
          );


        // ==================================================
        // FCM RESPONSE
        // ==================================================

        const result =
          await fcmResponse.json();


        if (!fcmResponse.ok) {

          console.error(
            "FCM error:",
            result
          );

          return new Response(
            JSON.stringify({

              success: false,

              message:
                "FCM notification failed",

              error:
                result,
            }),

            {
              status: 500,

              headers: {
                "Content-Type":
                  "application/json",
              },
            }
          );
        }


        // ==================================================
        // SUCCESS
        // ==================================================

        console.log(
          "FCM notification sent:",
          result
        );


        return new Response(
          JSON.stringify({

            success: true,

            message:
              "Notification sent successfully",

            response:
              result,
          }),

          {
            status: 200,

            headers: {
              "Content-Type":
                "application/json",
            },
          }
        );

      }


      // ====================================================
      // ERROR
      // ====================================================

      catch (error) {

        console.error(
          "Worker error:",
          error
        );

        return new Response(
          JSON.stringify({

            success: false,

            message:
              "Notification failed",

            error:
              error.message,
          }),

          {
            status: 500,

            headers: {
              "Content-Type":
                "application/json",
            },
          }
        );
      }
    }


    // ======================================================
    // POST /api/create-group
    // HUBS PAGE -> GROUPS TAB -> "Create Group"
    // ------------------------------------------------------
    // Creates the group document. Done here (Firestore-scoped
    // access token + REST API, same pattern as the cleanup jobs
    // above) rather than as a direct Firestore write from the
    // Flutter client, because the group password has to be
    // hashed somewhere the client can't tamper with -- see
    // hashPasswordWithSalt() above. Push notifications to the
    // selected members are NOT sent from here: the Flutter client
    // sends those itself, one per member, through the existing
    // POST / notification flow above (NotificationService.sendToUser
    // in the app), right after this call returns success.
    // ======================================================

    if (
      request.method === "POST" &&
      url.pathname === "/api/create-group"
    ) {
      try {
        const body = await request.json();

        const {
          groupId,
          groupName,
          groupProfileImage,
          adminUid,
          adminAccountId,
          members,
          password,
        } = body;

        // --------------------------------------------------
        // REQUIRED FIELDS
        // --------------------------------------------------

        if (!groupId || !groupId.toString().trim()) {
          return new Response(
            JSON.stringify({ success: false, message: "groupId is required" }),
            { status: 400, headers: { "Content-Type": "application/json" } }
          );
        }

        if (!groupName || !groupName.toString().trim()) {
          return new Response(
            JSON.stringify({ success: false, message: "groupName is required" }),
            { status: 400, headers: { "Content-Type": "application/json" } }
          );
        }

        if (!adminUid) {
          return new Response(
            JSON.stringify({ success: false, message: "adminUid is required" }),
            { status: 400, headers: { "Content-Type": "application/json" } }
          );
        }

        if (!password || !GROUP_PASSWORD_PATTERN.test(password.toString())) {
          return new Response(
            JSON.stringify({
              success: false,
              message:
                "Password must be exactly 6 characters, using only numbers and special characters",
            }),
            { status: 400, headers: { "Content-Type": "application/json" } }
          );
        }

        if (!env.FIREBASE_SERVICE_ACCOUNT) {
          throw new Error("FIREBASE_SERVICE_ACCOUNT secret is missing");
        }

        const serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
        const projectId = serviceAccount.project_id;

        const accessToken = await getGoogleAccessToken(
          serviceAccount,
          FIRESTORE_SCOPE
        );

        const cleanGroupId = groupId.toString().trim();
        const cleanGroupName = groupName.toString().trim();

        const cleanMembers = Array.isArray(members)
          ? [
              ...new Set(
                members
                  .map((uid) => (uid || "").toString().trim())
                  .filter((uid) => uid && uid !== adminUid)
              ),
            ]
          : [];

        // --------------------------------------------------
        // GROUP ID MUST BE UNIQUE
        // --------------------------------------------------

        const existing = await firestoreRunQuery(accessToken, projectId, {
          from: [{ collectionId: "groups" }],
          where: {
            fieldFilter: {
              field: { fieldPath: "groupId" },
              op: "EQUAL",
              value: { stringValue: cleanGroupId },
            },
          },
          limit: 1,
        });

        if (existing.length > 0) {
          return new Response(
            JSON.stringify({
              success: false,
              message:
                "That Group ID is already taken. Try a different group name.",
            }),
            { status: 409, headers: { "Content-Type": "application/json" } }
          );
        }

        // --------------------------------------------------
        // HASH PASSWORD (random salt + SHA-256)
        // --------------------------------------------------

        const passwordSalt = randomHexSalt();
        const passwordHash = await hashPasswordWithSalt(
          password.toString(),
          passwordSalt
        );

        // --------------------------------------------------
        // CREATE GROUP DOCUMENT
        // --------------------------------------------------

        const created = await firestoreCreateDocument(
          accessToken,
          projectId,
          "groups",
          {
            groupId: { stringValue: cleanGroupId },
            groupName: { stringValue: cleanGroupName },
            groupProfileImage: {
              stringValue: (groupProfileImage || "").toString(),
            },
            adminUid: { stringValue: adminUid },
            adminAccountId: {
              stringValue: (adminAccountId || "").toString(),
            },
            members: { arrayValue: { values: [{ stringValue: adminUid }] } },
            pendingMembers: {
              arrayValue: {
                values: cleanMembers.map((uid) => ({ stringValue: uid })),
              },
            },
            membersCount: { integerValue: "1" },
            passwordHash: { stringValue: passwordHash },
            passwordSalt: { stringValue: passwordSalt },
            createdAt: { timestampValue: new Date().toISOString() },
          }
        );

        console.log("Group created:", cleanGroupId, created.name);

        return new Response(
          JSON.stringify({
            success: true,
            message: "Group created",
            docId: documentIdFromName(created.name),
            groupId: cleanGroupId,
            pendingMembers: cleanMembers,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        );
      } catch (error) {
        console.error("Create group error:", error);

        return new Response(
          JSON.stringify({
            success: false,
            message: "Failed to create group",
            error: error.message,
          }),
          { status: 500, headers: { "Content-Type": "application/json" } }
        );
      }
    }


    // ======================================================
    // POST /api/join-group
    // HUBS PAGE -> GROUPS TAB -> "Join Group"
    // ------------------------------------------------------
    // Joins an existing group by Group ID + Group Password. Done
    // here (Firestore-scoped access token + REST API, same pattern
    // as /api/create-group above) rather than as a direct Firestore
    // write from the Flutter client, because checking the password
    // requires the passwordHash/passwordSalt fields, and the check
    // has to happen somewhere the client can't tamper with -- the
    // client never sees either field, only this endpoint's
    // success/failure response.
    // ======================================================

    if (
      request.method === "POST" &&
      url.pathname === "/api/join-group"
    ) {
      try {
        const body = await request.json();

        const { groupId, password, uid } = body;

        // --------------------------------------------------
        // REQUIRED FIELDS
        // --------------------------------------------------

        if (!groupId || !groupId.toString().trim()) {
          return new Response(
            JSON.stringify({ success: false, message: "groupId is required" }),
            { status: 400, headers: { "Content-Type": "application/json" } }
          );
        }

        if (!password || !password.toString()) {
          return new Response(
            JSON.stringify({ success: false, message: "password is required" }),
            { status: 400, headers: { "Content-Type": "application/json" } }
          );
        }

        if (!uid) {
          return new Response(
            JSON.stringify({ success: false, message: "uid is required" }),
            { status: 400, headers: { "Content-Type": "application/json" } }
          );
        }

        if (!env.FIREBASE_SERVICE_ACCOUNT) {
          throw new Error("FIREBASE_SERVICE_ACCOUNT secret is missing");
        }

        const serviceAccount = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
        const projectId = serviceAccount.project_id;

        const accessToken = await getGoogleAccessToken(
          serviceAccount,
          FIRESTORE_SCOPE
        );

        const cleanGroupId = groupId.toString().trim();

        // --------------------------------------------------
        // GROUP MUST EXIST (wrong Group ID -> error)
        // --------------------------------------------------

        const existing = await firestoreRunQuery(accessToken, projectId, {
          from: [{ collectionId: "groups" }],
          where: {
            fieldFilter: {
              field: { fieldPath: "groupId" },
              op: "EQUAL",
              value: { stringValue: cleanGroupId },
            },
          },
          limit: 1,
        });

        if (existing.length === 0) {
          return new Response(
            JSON.stringify({
              success: false,
              message: "No group found with that Group ID",
            }),
            { status: 404, headers: { "Content-Type": "application/json" } }
          );
        }

        const groupDoc = existing[0];

        // --------------------------------------------------
        // PASSWORD MUST MATCH (wrong password -> error)
        // --------------------------------------------------

        const passwordSalt = stringField(groupDoc, "passwordSalt");
        const passwordHash = stringField(groupDoc, "passwordHash");

        const attemptHash = await hashPasswordWithSalt(
          password.toString(),
          passwordSalt
        );

        if (!passwordSalt || !passwordHash || attemptHash !== passwordHash) {
          return new Response(
            JSON.stringify({
              success: false,
              message: "Incorrect group password",
            }),
            { status: 401, headers: { "Content-Type": "application/json" } }
          );
        }

        // --------------------------------------------------
        // ALREADY A MEMBER -> "already joined" message,
        // no duplicate membership created.
        // --------------------------------------------------

        const members = arrayFieldStrings(groupDoc, "members");
        const groupName = stringField(groupDoc, "groupName");
        const groupProfileImage = stringField(groupDoc, "groupProfileImage");
        const adminUid = stringField(groupDoc, "adminUid");
        const docId = documentIdFromName(groupDoc.name);

        if (members.includes(uid)) {
          return new Response(
            JSON.stringify({
              success: false,
              alreadyMember: true,
              message: "You're already a member of this group",
              docId,
              groupId: cleanGroupId,
              groupName,
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          );
        }

        // --------------------------------------------------
        // ADD TO MEMBERS
        // --------------------------------------------------

        const newMembers = [...members, uid];
        const pendingMembers = arrayFieldStrings(groupDoc, "pendingMembers").filter(
          (pendingUid) => pendingUid !== uid
        );

        await firestoreUpdateDocument(
          accessToken,
          groupDoc.name,
          {
            members: {
              arrayValue: { values: newMembers.map((u) => ({ stringValue: u })) },
            },
            membersCount: { integerValue: String(newMembers.length) },
            pendingMembers: {
              arrayValue: {
                values: pendingMembers.map((u) => ({ stringValue: u })),
              },
            },
          },
          ["members", "membersCount", "pendingMembers"]
        );

        console.log("User joined group:", cleanGroupId, uid);

        return new Response(
          JSON.stringify({
            success: true,
            message: "Joined group",
            docId,
            groupId: cleanGroupId,
            groupName,
            groupProfileImage,
            adminUid,
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        );
      } catch (error) {
        console.error("Join group error:", error);

        return new Response(
          JSON.stringify({
            success: false,
            message: "Failed to join group",
            error: error.message,
          }),
          { status: 500, headers: { "Content-Type": "application/json" } }
        );
      }
    }


    // ======================================================
    // OTHER ENDPOINTS
    // ======================================================

    return new Response(
      JSON.stringify({

        success: false,

        message:
          "Endpoint not found",

        endpoint:
          url.pathname,
      }),

      {
        status: 404,

        headers: {
          "Content-Type":
            "application/json",
        },
      }
    );
  },
};