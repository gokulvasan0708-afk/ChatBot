async function createAccessToken(serviceAccount) {
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
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };

  const headerEncoded = base64url(
    JSON.stringify(header)
  );

  const payloadEncoded = base64url(
    JSON.stringify(payload)
  );

  const unsignedToken =
    `${headerEncoded}.${payloadEncoded}`;

  const privateKeyPem =
    serviceAccount.private_key.replace(
      /\\n/g,
      "\n"
    );

  const pemContents = privateKeyPem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");

  const binaryKey = Uint8Array.from(
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


async function getGoogleAccessToken(
  serviceAccount
) {
  const jwt =
    await createAccessToken(serviceAccount);

  const response = await fetch(
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


export default {
  async fetch(request, env) {

    // ======================================================
    // GET TEST
    // ======================================================

    if (request.method === "GET") {
      return new Response(
        JSON.stringify({
          success: true,
          message:
            "chatbot Notification Worker is running!",
        }),
        {
          headers: {
            "Content-Type":
              "application/json",
          },
        }
      );
    }


    // ======================================================
    // ONLY POST
    // ======================================================

    if (request.method !== "POST") {
      return new Response(
        JSON.stringify({
          success: false,
          message:
            "Method not allowed",
        }),
        {
          status: 405,
          headers: {
            "Content-Type":
              "application/json",
          },
        }
      );
    }


    try {

      // ====================================================
      // READ REQUEST
      // ====================================================

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


      // ====================================================
      // CHECK FCM TOKEN
      // ====================================================

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


      // ====================================================
      // CHECK SENDER NAME
      // ====================================================

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


      // ====================================================
      // CHECK MESSAGE
      // ====================================================

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


      // ====================================================
      // FIREBASE SERVICE ACCOUNT
      // ====================================================

      if (!env.FIREBASE_SERVICE_ACCOUNT) {
        throw new Error(
          "FIREBASE_SERVICE_ACCOUNT secret is missing"
        );
      }

      const serviceAccount =
        JSON.parse(
          env.FIREBASE_SERVICE_ACCOUNT
        );


      // ====================================================
      // GOOGLE ACCESS TOKEN
      // ====================================================

      const accessToken =
        await getGoogleAccessToken(
          serviceAccount
        );


      // ====================================================
      // FCM HTTP V1 URL
      // ====================================================

      const fcmUrl =
        `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;


      // ====================================================
      // SEND FCM
      // ====================================================

      const fcmResponse =
        await fetch(
          fcmUrl,
          {
            method: "POST",

            headers: {
              "Authorization":
                `Bearer ${accessToken}`,

              "Content-Type":
                "application/json",
            },

            body: JSON.stringify({

              message: {

                token: fcmToken,

                notification: {
                  title: senderName,
                  body: message,
                },

                data: {
                  type: "chat",

                  senderUid:
                    senderUid ?? "",
                },

                android: {
                  priority: "HIGH",

                  notification: {
                    channel_id:
                      "chat_messages",

                    sound:
                      "default",

                    icon: "ic_stat_nexus",
                  },
                },

              },

            }),

          }
        );


      // ====================================================
      // FCM RESPONSE
      // ====================================================

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

            error: result,
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


      // ====================================================
      // SUCCESS
      // ====================================================

      console.log(
        "FCM notification sent:",
        result
      );

      return new Response(
        JSON.stringify({
          success: true,

          message:
            "Notification sent successfully",

          response: result,
        }),
        {
          status: 200,

          headers: {
            "Content-Type":
              "application/json",
          },
        }
      );


    } catch (error) {

      // ====================================================
      // ERROR
      // ====================================================

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
  },
};