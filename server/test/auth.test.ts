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

  it("poisto: yksin luotu heti, muiden sisältö → ehdotus, vastustus pysäyttää, määräaika toteuttaa", async () => {
    const owner = await signIn("owner", "laite-O");
    await app.request("/api/public/spots/s1", { method: "PUT", ...asUser(owner.token), body: spot("laite-O") });
    // Ei muiden sisältöä → poistuu heti.
    expect((await app.request("/api/public/spots/s1?ownerKey=laite-O", { method: "DELETE", ...asUser(owner.token) })).status).toBe(200);

    // Uusi spotti, johon toinen kommentoi.
    await app.request("/api/public/spots/s2", { method: "PUT", ...asUser(owner.token), body: spot("laite-O", "Yhteinen") });
    const other = await signIn("other");
    await app.request("/api/me", { method: "PUT", ...asUser(other.token), body: JSON.stringify({ nickname: "Toinen" }) });
    await app.request("/api/public/spots/s2/comments", { method: "POST", ...asUser(other.token), body: JSON.stringify({ text: "Hyvä paikka" }) });

    const del = await app.request("/api/public/spots/s2?ownerKey=laite-O", { method: "DELETE", ...asUser(owner.token) });
    expect(del.status).toBe(202);
    const listed = await (await app.request("/api/public/spots", client)).json();
    expect(listed.spots.find((s: { id: string }) => s.id === "s2").deletionProposed).toBeTruthy();

    // Ulkopuolinen ei voi vastustaa, osallistunut voi.
    const stranger = await signIn("stranger");
    expect((await app.request("/api/public/spots/s2/deletion/object", { method: "POST", ...asUser(stranger.token), body: "{}" })).status).toBe(403);
    expect((await app.request("/api/public/spots/s2/deletion/object", { method: "POST", ...asUser(other.token), body: "{}" })).status).toBe(200);
    expect((await (await app.request("/api/public/spots/s2/deletion", client)).json()).proposal).toBeNull();

    // Uusi ehdotus ilman vastustusta toteutuu määräajan jälkeen.
    await app.request("/api/public/spots/s2?ownerKey=laite-O", { method: "DELETE", ...asUser(owner.token) });
    const later = createApp({
      config: loadConfig({ NOSTE_TOKEN: "secret", CLIENT_TOKEN: "client", DATA_DIR: join(dir, "d2"), TILE_CACHE_DIR: join(dir, "t2") } as NodeJS.ProcessEnv),
      db: database.db, fetchImpl: (async () => new Response("{}")) as never,
      now: () => new Date(Date.now() + 8 * 24 * 3600 * 1000),
    });
    const executed = await later.runGovernance();
    expect(executed).toEqual(["s2"]);
    const after = await (await later.app.request("/api/public/spots", client)).json();
    expect(after.spots.map((s: { id: string }) => s.id)).not.toContain("s2");
  });

  it("ilmoitus, oman kommentin poisto ja oma sisältö", async () => {
    const { token } = await signIn("u1", "laite-1");
    await app.request("/api/me", { method: "PUT", ...asUser(token), body: JSON.stringify({ nickname: "Eka" }) });
    await app.request("/api/public/spots/s1", { method: "PUT", ...asUser(token), body: spot("laite-1") });
    const posted = await (await app.request("/api/public/spots/s1/comments", { method: "POST", ...asUser(token), body: JSON.stringify({ text: "Moi" }) })).json();

    const report = await app.request("/api/public/reports", { method: "POST", ...client, body: JSON.stringify({ targetType: "comment", targetId: posted.comment.id, reason: "roskaa", ownerKey: "laite-9" }) });
    expect(report.status).toBe(200);
    const again = await (await app.request("/api/public/reports", { method: "POST", ...client, body: JSON.stringify({ targetType: "comment", targetId: posted.comment.id, reason: "roskaa", ownerKey: "laite-9" }) })).json();
    expect(again.duplicate).toBe(true);
    expect((await app.request("/api/reports", client)).status).toBe(401);
    const admin = { headers: { authorization: "Bearer secret" } };
    const open = await (await app.request("/api/reports", admin)).json();
    expect(open.reports).toHaveLength(1);
    expect((await app.request(`/api/reports/${open.reports[0].id}/resolve`, { method: "POST", ...admin, body: JSON.stringify({ resolution: "poistettu" }) })).status).toBe(200);

    const mine = await (await app.request("/api/me/content", asUser(token))).json();
    expect(mine.spots).toHaveLength(1);
    expect(mine.comments).toHaveLength(1);

    const other = await signIn("u2");
    expect((await app.request(`/api/public/spots/s1/comments/${posted.comment.id}`, { method: "DELETE", ...asUser(other.token) })).status).toBe(403);
    expect((await app.request(`/api/public/spots/s1/comments/${posted.comment.id}`, { method: "DELETE", ...asUser(token) })).status).toBe(200);
    const comments = await (await app.request("/api/public/spots/s1/comments", client)).json();
    expect(comments.comments).toHaveLength(0);
  });

  it("wiki: kirjautunut täydentää muiden spottia, ei siirrä; historia nimillä; palautus", async () => {
    const owner = await signIn("owner", "laite-O");
    await app.request("/api/me", { method: "PUT", ...asUser(owner.token), body: JSON.stringify({ nickname: "Omistaja" }) });
    await app.request("/api/public/spots/w1", { method: "PUT", ...asUser(owner.token), body: spot("laite-O", "Ranta") });

    const editor = await signIn("editor", "laite-E");
    // Ilman nimimerkkiä ei saa muokata.
    expect((await app.request("/api/public/spots/w1", { method: "PUT", ...asUser(editor.token),
      body: JSON.stringify({ name: "Ranta", latitude: 60.15, longitude: 24.87, waterType: "sea", ownerKey: "laite-E", description: "Parkki tien päässä" }) })).status).toBe(403);
    await app.request("/api/me", { method: "PUT", ...asUser(editor.token), body: JSON.stringify({ nickname: "Muokkaaja" }) });
    const wiki = await app.request("/api/public/spots/w1", { method: "PUT", ...asUser(editor.token),
      body: JSON.stringify({ name: "Ranta", latitude: 60.15, longitude: 24.87, waterType: "sea", ownerKey: "laite-E", description: "Parkki tien päässä", goodDirections: [5, 6] }) });
    expect(wiki.status).toBe(200);
    // Siirto tai nimeäminen ei onnistu muulta kuin omistajalta.
    const moved = await app.request("/api/public/spots/w1", { method: "PUT", ...asUser(editor.token),
      body: JSON.stringify({ name: "Ranta", latitude: 60.3, longitude: 24.87, waterType: "sea", ownerKey: "laite-E", description: "Parkki tien päässä", goodDirections: [5, 6] }) });
    expect(moved.status).toBe(200); // sijainti jätetään omistajan asettamaksi
    const renamed = await app.request("/api/public/spots/w1", { method: "PUT", ...asUser(editor.token),
      body: JSON.stringify({ name: "Uusi", latitude: 60.15, longitude: 24.87, waterType: "sea", ownerKey: "laite-E" }) });
    expect(renamed.status).toBe(403);

    const list = await (await app.request("/api/public/spots", client)).json();
    expect(list.spots[0].description).toBe("Parkki tien päässä");
    // Wikimuokkaus ei siirtänyt eikä muuttanut tarkkuutta.
    expect(list.spots[0].latitude).toBe(60.15);
    // Omistaja on edelleen omistaja.
    const asOwner = await (await app.request("/api/public/spots", asUser(owner.token))).json();
    expect(asOwner.spots[0].mine).toBe(true);

    const history = await (await app.request("/api/public/spots/w1/history", client)).json();
    expect(history.revisions.map((r: { editor: string }) => r.editor)).toEqual(["Muokkaaja", "Muokkaaja", "Omistaja"]);

    // Palautus ensimmäiseen versioon: kuvaus katoaa, historia kasvaa.
    const first = history.revisions[2].id;
    expect((await app.request(`/api/public/spots/w1/history/${first}/restore`, { method: "POST", ...asUser(editor.token), body: "{}" })).status).toBe(200);
    const after = await (await app.request("/api/public/spots", client)).json();
    expect(after.spots[0].description).toBeUndefined();
    expect((await (await app.request("/api/public/spots/w1/history", client)).json()).revisions).toHaveLength(4);
  });

  it("ilmoitukset: kommentti omistajalle, poistoehdotus osallistuneille, luetuksi merkintä", async () => {
    const owner = await signIn("owner", "laite-O");
    await app.request("/api/public/spots/n1", { method: "PUT", ...asUser(owner.token), body: spot("laite-O", "Ilmoitusranta") });
    const other = await signIn("other");
    await app.request("/api/me", { method: "PUT", ...asUser(other.token), body: JSON.stringify({ nickname: "Toinen" }) });
    await app.request("/api/public/spots/n1/comments", { method: "POST", ...asUser(other.token), body: JSON.stringify({ text: "Toimii" }) });

    let mine = await (await app.request("/api/me/notifications", asUser(owner.token))).json();
    expect(mine.unread).toBe(1);
    expect(mine.notifications[0]).toMatchObject({ kind: "comment", spotId: "n1" });
    // Kommentoija ei saa ilmoitusta omasta kommentistaan.
    expect((await (await app.request("/api/me/notifications", asUser(other.token))).json()).unread).toBe(0);

    // Poistoehdotus → kommentoinut saa ilmoituksen, ehdottaja ei.
    await app.request("/api/public/spots/n1?ownerKey=laite-O", { method: "DELETE", ...asUser(owner.token) });
    const theirs = await (await app.request("/api/me/notifications", asUser(other.token))).json();
    expect(theirs.unread).toBe(1);
    expect(theirs.notifications[0].kind).toBe("deletion_proposed");

    await app.request("/api/me/notifications/read", { method: "POST", ...asUser(owner.token), body: "{}" });
    mine = await (await app.request("/api/me/notifications", asUser(owner.token))).json();
    expect(mine.unread).toBe(0);
  });

  it("tilin synkka: spotit ja hälytykset tilin alla, kelivahti ilmoittaa appiin", async () => {
    const { token } = await signIn("sync-user", "laite-S");
    expect((await app.request("/api/me/spots", asUser(token))).status).toBe(200);
    const spots = [{ id: "s1", name: "Koti", latitude: 60.1, longitude: 24.9, waterType: "sea", sports: [], isFavorite: true, notes: "" }];
    expect((await app.request("/api/me/spots", { method: "PUT", ...asUser(token), body: JSON.stringify(spots) })).status).toBe(200);
    expect((await app.request("/api/me/spots", { method: "PUT", ...asUser(token), body: JSON.stringify([{ id: 1 }]) })).status).toBe(400);
    const stored = await (await app.request("/api/me/spots", asUser(token))).json();
    expect(stored.spots).toHaveLength(1);
    // Toinen käyttäjä ei näe.
    const other = await signIn("other");
    expect((await (await app.request("/api/me/spots", asUser(other.token))).json()).spots).toHaveLength(0);

    const alerts = [{ id: "a1", spotId: "s1", spotName: "Koti", latitude: 60.1, longitude: 24.9, waterType: "sea", minWind: 8, minHours: 2, enabled: true }];
    expect((await app.request("/api/me/alerts", { method: "PUT", ...asUser(token), body: JSON.stringify(alerts) })).status).toBe(200);
    // Kelivahti käyttää tilin hälytystä ja ilmoittaa appiin (ei ntfy), sama ikkuna vain kerran.
    const built = createApp({
      config: loadConfig({ NOSTE_TOKEN: "secret", CLIENT_TOKEN: "client", DATA_DIR: join(dir, "k"), TILE_CACHE_DIR: join(dir, "kt") } as NodeJS.ProcessEnv),
      db: database.db,
      fetchImpl: (async (url: string) => new Response(JSON.stringify(url.includes("api.open-meteo.com") ? {
        hourly: { time: ["2026-08-21T10:00", "2026-08-21T11:00", "2026-08-21T12:00"], wind_speed_10m: [9, 10, 11], wind_gusts_10m: [12, 13, 15], wind_direction_10m: [225, 230, 240] },
      } : {}), { status: 200 })) as never,
      now: () => new Date("2026-08-21T08:00:00Z"),
    });
    const results = await built.checkAlerts();
    expect(results).toHaveLength(1);
    await built.checkAlerts();
    const inbox = await (await app.request("/api/me/notifications", asUser(token))).json();
    expect(inbox.notifications.filter((n: { kind: string }) => n.kind === "kelivahti")).toHaveLength(1);
  });

  it("sessioreittejä ei ole — GPS ja terveysdata pysyvät puhelimessa", async () => {
    expect((await app.request("/api/sessions", { headers: { authorization: "Bearer secret" } })).status).toBe(404);
  });
});
