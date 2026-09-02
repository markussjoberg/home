import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { createTestDb, type DbHandle } from "../src/db/index.js";

const client = { headers: { authorization: "Bearer client", "content-type": "application/json" } };
const spot = (ownerKey: string, name = "Testiranta") => JSON.stringify({
  name, latitude: 60.15, longitude: 24.87, waterType: "sea", ownerKey,
});

describe("tunnukset", () => {
  let dir: string;
  let database: DbHandle;
  let app: ReturnType<typeof createApp>["app"];

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "noste-auth-"));
    database = await createTestDb();
    const config = loadConfig({
      NOSTE_TOKEN: "secret", CLIENT_TOKEN: "client", DATA_DIR: join(dir, "data"), TILE_CACHE_DIR: join(dir, "tiles"),
    } as NodeJS.ProcessEnv);
    ({ app } = createApp({
      config,
      db: database.db,
      fetchImpl: (async () => new Response("{}")) as never,
      // Stubi: "apple:<sub>" kelpaa, muu hylätään.
      verifyIdentity: async (token) => {
        if (!token.startsWith("apple:")) throw new Error("bad token");
        return { sub: token.slice(6), email: `${token.slice(6)}@example.com` };
      },
    }));
  });

  afterEach(async () => {
    await database.close();
    await rm(dir, { recursive: true, force: true });
  });

  const signIn = async (sub: string, ownerKey?: string) => {
    const res = await app.request("/api/auth/apple", {
      method: "POST", ...client, body: JSON.stringify({ identityToken: `apple:${sub}`, ownerKey }),
    });
    expect(res.status).toBe(200);
    return (await res.json()) as { token: string; user: { id: string; nickname: string | null } };
  };
  const asUser = (token: string) => ({ headers: { ...client.headers, "x-user-token": token } });

  it("kirjautuminen, nimimerkki ja uloskirjautuminen", async () => {
    const bad = await app.request("/api/auth/apple", { method: "POST", ...client, body: JSON.stringify({ identityToken: "x" }) });
    expect(bad.status).toBe(401);

    const { token, user } = await signIn("sub-1");
    expect(user.nickname).toBeNull();
    const me = await (await app.request("/api/me", asUser(token))).json();
    expect(me.user.id).toBe(user.id);

    expect((await app.request("/api/me", { method: "PUT", ...asUser(token), body: JSON.stringify({ nickname: "a" }) })).status).toBe(400);
    const named = await app.request("/api/me", { method: "PUT", ...asUser(token), body: JSON.stringify({ nickname: "Markus_W" }) });
    expect(named.status).toBe(200);
    expect((await named.json()).user.nickname).toBe("Markus_W");

    // Toinen käyttäjä ei saa samaa nimeä eri kirjainkoolla.
    const other = await signIn("sub-2");
    const clash = await app.request("/api/me", { method: "PUT", ...asUser(other.token), body: JSON.stringify({ nickname: "markus_w" }) });
    expect(clash.status).toBe(409);

    await app.request("/api/auth/logout", { method: "POST", ...asUser(token) });
    expect((await app.request("/api/me", asUser(token))).status).toBe(401);
  });

  it("laiteavaimen spotit seuraavat tunnusta toiselle laitteelle", async () => {
    // Anonyymi julkaisu laitteelta A.
    await app.request("/api/public/spots/s1", { method: "PUT", ...client, body: spot("laite-A") });
    // Kirjautuminen laitteella A sitoo avaimen; laite B saman tunnuksen alla saa muokata.
    const { token } = await signIn("sub-1", "laite-A");
    const edit = await app.request("/api/public/spots/s1", { method: "PUT", ...asUser(token), body: spot("laite-B", "Uusi nimi") });
    expect(edit.status).toBe(200);
    // Ilman tunnusta laite B ei saa.
    const anon = await app.request("/api/public/spots/s1", { method: "PUT", ...client, body: spot("laite-B", "Kaapattu") });
    expect(anon.status).toBe(403);
    const list = await (await app.request("/api/public/spots", asUser(token))).json();
    expect(list.spots[0]).toMatchObject({ name: "Uusi nimi", mine: true });
    const listAnon = await (await app.request("/api/public/spots", client)).json();
    expect(listAnon.spots[0].mine).toBe(false);
    expect(listAnon.spots[0].ownerUserId).toBeUndefined();
  });

  it("kirjautuneen kommentin kirjoittaja on nimimerkki, ei runko", async () => {
    await app.request("/api/public/spots/s1", { method: "PUT", ...client, body: spot("laite-A") });
    const { token } = await signIn("sub-1");
    await app.request("/api/me", { method: "PUT", ...asUser(token), body: JSON.stringify({ nickname: "Tuulinen" }) });
    const post = await app.request("/api/public/spots/s1/comments", {
      method: "POST", ...asUser(token), body: JSON.stringify({ author: "Huijari", text: "SW 8 m/s toimi" }),
    });
    expect(post.status).toBe(200);
    const comments = await (await app.request("/api/public/spots/s1/comments", client)).json();
    expect(comments.comments[0].author).toBe("Tuulinen");
  });
});
