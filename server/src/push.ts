/**
 * APNs-push HTTP/2:lla ilman kirjastoja: JWT (ES256) allekirjoitetaan Applen
 * .p8-avaimella (jose), pyyntö api.push.apple.comiin node:http2:lla.
 * Kytkeytyy päälle vasta kun APNS_KEY_ID, APNS_TEAM_ID ja APNS_KEY_P8 on
 * asetettu — ilman niitä ilmoitukset jäävät appin sisäisiksi.
 */
import { connect } from "node:http2";
import { and, eq } from "drizzle-orm";
import { SignJWT, importPKCS8 } from "jose";
import type { Db } from "./db/index.js";
import { pushTokens } from "./db/schema.js";

export interface PushConfig {
  keyId: string;
  teamId: string;
  /** .p8-avaimen sisältö (PEM). */
  privateKeyPem: string;
  /** Bundle id (apns-topic). */
  topic: string;
}

export interface PushMessage {
  title: string;
  body: string;
  /** Appin reititys: mihin ilmoitus vie. */
  data?: Record<string, string>;
}

export type PushSender = (token: string, sandbox: boolean, message: PushMessage) => Promise<"ok" | "invalid" | "failed">;

export function pushConfigFromEnv(env: NodeJS.ProcessEnv, topic: string): PushConfig | null {
  const keyId = env.APNS_KEY_ID ?? "";
  const teamId = env.APNS_TEAM_ID ?? "";
  const raw = env.APNS_KEY_P8 ?? "";
  if (!keyId || !teamId || !raw) return null;
  // Sallitaan sekä PEM suoraan että base64-koodattu PEM (.env-ystävällinen).
  const privateKeyPem = raw.includes("BEGIN PRIVATE KEY") ? raw.replace(/\\n/g, "\n") : Buffer.from(raw, "base64").toString("utf8");
  return { keyId, teamId, privateKeyPem, topic };
}

/** Lähettäjä, joka allekirjoittaa JWT:n (voimassa ≤ 1 h, käytetään uudelleen 50 min). */
export function createApnsSender(config: PushConfig): PushSender {
  let cached: { jwt: string; issuedAt: number } | null = null;
  const jwt = async () => {
    const now = Date.now();
    if (cached && now - cached.issuedAt < 50 * 60 * 1000) return cached.jwt;
    const key = await importPKCS8(config.privateKeyPem, "ES256");
    const token = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: config.keyId })
      .setIssuer(config.teamId).setIssuedAt().sign(key);
    cached = { jwt: token, issuedAt: now };
    return token;
  };

  return (deviceToken, sandbox, message) => new Promise((resolve) => {
    jwt().then((bearer) => {
      const host = sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
      const client = connect(host);
      client.on("error", () => { resolve("failed"); client.close(); });
      const body = JSON.stringify({
        aps: { alert: { title: message.title, body: message.body }, sound: "default" },
        ...(message.data ?? {}),
      });
      const req = client.request({
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        authorization: `bearer ${bearer}`,
        "apns-topic": config.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      });
      let status = 0;
      req.on("response", (headers) => { status = Number(headers[":status"] ?? 0); });
      req.on("end", () => {
        client.close();
        // 410 = tunniste ei enää voimassa → poistetaan; 400 BadDeviceToken samoin.
        resolve(status === 200 ? "ok" : status === 410 || status === 400 ? "invalid" : "failed");
      });
      req.on("error", () => { resolve("failed"); client.close(); });
      req.end(body);
    }).catch(() => resolve("failed"));
  });
}

export async function registerPushToken(db: Db, userId: string, token: string, sandbox: boolean, now: Date): Promise<void> {
  await db.insert(pushTokens).values({ token, userId, sandbox: sandbox ? 1 : 0, updatedAt: now })
    .onConflictDoUpdate({ target: pushTokens.token, set: { userId, sandbox: sandbox ? 1 : 0, updatedAt: now } });
}

export async function removePushToken(db: Db, token: string): Promise<void> {
  await db.delete(pushTokens).where(eq(pushTokens.token, token));
}

export async function removeUserPushTokens(db: Db, userId: string): Promise<void> {
  await db.delete(pushTokens).where(eq(pushTokens.userId, userId));
}

/** Lähettää käyttäjän kaikille laitteille; kelvottomat tunnisteet siivotaan. */
export async function pushToUser(db: Db, sender: PushSender | null, userId: string, message: PushMessage): Promise<number> {
  if (!sender) return 0;
  const rows = await db.select().from(pushTokens).where(eq(pushTokens.userId, userId));
  let sent = 0;
  for (const row of rows) {
    const result = await sender(row.token, row.sandbox === 1, message);
    if (result === "ok") sent++;
    else if (result === "invalid") await db.delete(pushTokens).where(and(eq(pushTokens.token, row.token), eq(pushTokens.userId, userId)));
  }
  return sent;
}
