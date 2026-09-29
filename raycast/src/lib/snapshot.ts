import { Snapshot } from "./model";

/** Station serves its current snapshot on loopback while it runs. */
export const STATION_SNAPSHOT_URL = "http://127.0.0.1:47400/prs.json";

/** null when Station isn't running or isn't signed in yet. */
export async function fetchSnapshot(url: string = STATION_SNAPSHOT_URL, timeoutMs = 1500): Promise<Snapshot | null> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
    if (!response.ok) return null;
    return parseSnapshot(await response.json());
  } catch {
    return null;
  }
}

export function parseSnapshot(body: unknown): Snapshot | null {
  if (typeof body !== "object" || body === null) return null;
  const raw = body as Partial<Snapshot>;
  if (!Array.isArray(raw.prs) || typeof raw.writtenAt !== "string") return null;
  return {
    writtenAt: raw.writtenAt,
    prs: raw.prs.map((pr) => ({
      ...pr,
      checks: pr.checks ?? [],
      author: pr.author ?? "",
      status: pr.status ?? "open",
      summary: pr.summary ?? "",
      headRefName: pr.headRefName ?? "",
      baseRefName: pr.baseRefName ?? "",
      mergeState: pr.mergeState ?? "unknown",
      review: pr.review ?? "none",
    })),
    pinnedIDs: raw.pinnedIDs ?? [],
    sections: raw.sections ?? [],
    colorProfile: raw.colorProfile === "deuteranopia" ? "deuteranopia" : "default",
  };
}
