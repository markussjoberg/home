/** Palvelimen asetukset ympäristömuuttujista. */
export interface Config {
  port: number;
  /** MML avoin karttakuvapalvelu -avain (maastokarttatiilet). */
  mmlApiKey: string;
  /** Merikarttatiilien WMTS-osoite, {z}/{y}/{x} korvataan. */
  marineTileTemplate: string;
  /** Bearer-token, jolla appi tunnistautuu (synkka, kelivahti). */
  apiToken: string;
  /** ntfy-aiheen osoite kelivahti-ilmoituksille (esim. https://ntfy.sh/oma-salainen-aihe). Tyhjä = ei ilmoituksia. */
  ntfyUrl: string;
  /** Lipas-rajapinnan juuri (liikuntapaikat, mm. uimarannat). */
  lipasBase: string;
  dataDir: string;
  tileCacheDir: string;
  /** Tiilivälimuistin elinikä sekunteina (oletus 30 vrk). */
  tileCacheTtl: number;
  /** Ennustevälimuistin elinikä sekunteina. */
  forecastCacheTtl: number;
}

export const DEFAULT_MARINE_TEMPLATE =
  "https://julkinen.traficom.fi/rasteripalvelu/wmts?service=WMTS&request=GetTile&version=1.0.0" +
  "&layer=Traficom:Merikarttasarja%20C&style=default&tilematrixset=WGS84_Pseudo-Mercator" +
  "&format=image/png&TileMatrix={z}&TileRow={y}&TileCol={x}";

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return {
    port: Number(env.PORT ?? 8080),
    mmlApiKey: env.MML_API_KEY ?? "",
    marineTileTemplate: env.MARINE_TILE_TEMPLATE ?? DEFAULT_MARINE_TEMPLATE,
    apiToken: env.NOSTE_TOKEN ?? "",
    ntfyUrl: env.NTFY_URL ?? "",
    lipasBase: env.LIPAS_BASE ?? "https://lipas.cc.jyu.fi/api",
    dataDir: env.DATA_DIR ?? "./data",
    tileCacheDir: env.TILE_CACHE_DIR ?? "./data/tiles",
    tileCacheTtl: Number(env.TILE_CACHE_TTL ?? 30 * 24 * 3600),
    forecastCacheTtl: Number(env.FORECAST_CACHE_TTL ?? 900),
  };
}
