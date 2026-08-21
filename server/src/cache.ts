/** Kevyt TTL-välimuisti muistiin (ennusteet, havainnot). */
export class TtlCache<V> {
  private entries = new Map<string, { value: V; expires: number }>();

  constructor(private readonly ttlSeconds: number, private readonly maxEntries = 1000) {}

  get(key: string, now = Date.now()): V | undefined {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (entry.expires < now) {
      this.entries.delete(key);
      return undefined;
    }
    return entry.value;
  }

  set(key: string, value: V, now = Date.now()): void {
    if (this.entries.size >= this.maxEntries) {
      // Yksinkertainen siivous: pudota vanhin.
      const oldest = this.entries.keys().next().value;
      if (oldest !== undefined) this.entries.delete(oldest);
    }
    this.entries.set(key, { value, expires: now + this.ttlSeconds * 1000 });
  }

  /** Hakee välimuistista tai tuottaa ja tallettaa. */
  async getOrSet(key: string, produce: () => Promise<V>): Promise<V> {
    const hit = this.get(key);
    if (hit !== undefined) return hit;
    const value = await produce();
    this.set(key, value);
    return value;
  }
}
