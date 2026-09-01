/**
 * Kelivahti: spotille asetetaan tuuli-ikkuna (nopeus + suunta), ja palvelin etsii
 * ennusteesta yhtenäiset jaksot jotka osuvat ikkunaan. Osumat talletetaan,
 * näkyvät APIsta ja ilmoitetaan ntfy:llä (app.ts notifyNewWindows).
 */
import type { WindHour } from "./openmeteo.js";

export interface Alert {
  id: string;
  spotId: string;
  spotName: string;
  /** m/s */
  minWind: number;
  /** m/s; puuttuva = ei ylärajaa */
  maxWind?: number;
  /** Suuntasektori asteina, myötäpäivään from→to; from > to = sektori pohjoisen yli. */
  directionFrom?: number;
  directionTo?: number;
  /** Vaihtoehto sektorille: sallitut ilmansuunnat indekseinä 0–7 (0 = N, 45° välein). */
  goodDirections?: number[];
  /** Kuinka monta peräkkäistä tuntia ikkunassa vaaditaan (oletus 2). */
  minHours?: number;
  enabled: boolean;
}

/** Suunta-asteet → ilmansuuntaindeksi 0–7 (sama pyöristys kuin appin NosteCoressa). */
export function compassOctant(degrees: number): number {
  const index = Math.round((((degrees % 360) + 360) % 360) / 45) % 8;
  return index;
}

export interface AlertWindow {
  start: string;
  end: string;
  hours: number;
  maxSpeed: number;
}

export function directionInSector(direction: number, from?: number, to?: number): boolean {
  if (from === undefined || to === undefined) return true;
  const d = ((direction % 360) + 360) % 360;
  const f = ((from % 360) + 360) % 360;
  const t = ((to % 360) + 360) % 360;
  if (f <= t) return d >= f && d <= t;
  return d >= f || d <= t; // sektori kiertyy pohjoisen yli, esim. 300°–45°
}

export function hourMatches(alert: Alert, hour: WindHour): boolean {
  if (hour.speed < alert.minWind) return false;
  if (alert.maxWind !== undefined && hour.speed > alert.maxWind) return false;
  if (alert.goodDirections && alert.goodDirections.length > 0) {
    return alert.goodDirections.includes(compassOctant(hour.direction));
  }
  return directionInSector(hour.direction, alert.directionFrom, alert.directionTo);
}

/** Etsii ennusteesta yhtenäiset, riittävän pitkät osumaikkunat. */
export function matchAlert(alert: Alert, wind: WindHour[]): AlertWindow[] {
  const minHours = alert.minHours ?? 2;
  const windows: AlertWindow[] = [];
  let run: WindHour[] = [];

  const close = () => {
    if (run.length >= minHours) {
      windows.push({
        start: run[0]!.time,
        end: run[run.length - 1]!.time,
        hours: run.length,
        maxSpeed: Math.max(...run.map((h) => h.speed)),
      });
    }
    run = [];
  };

  for (const hour of wind) {
    if (hourMatches(alert, hour)) {
      run.push(hour);
    } else {
      close();
    }
  }
  close();
  return windows;
}
