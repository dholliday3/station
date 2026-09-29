import { ActivityMap, PRActivity } from "./activity";
import { CheckResult, LoadedPRs, PullRequest } from "./model";

const ago = (minutes: number, now: number) => new Date(now - minutes * 60_000).toISOString();
const passing = (n: number): CheckResult[] =>
  Array.from({ length: n }, (_, i) => ({ name: `job ${i + 1}`, state: "success" }));

function pr(
  now: number,
  fields: Partial<PullRequest> & Pick<PullRequest, "id" | "repo" | "number" | "title">,
): PullRequest {
  return {
    url: `https://github.com/${fields.repo}/pull/${fields.number}`,
    isDraft: false,
    updatedAt: ago(60, now),
    headSha: "4f1c2a9d8e7b6c5a4f3e2d1c0b9a8f7e6d5c4b3a",
    checks: passing(12),
    author: "you",
    status: "open",
    summary: "",
    headRefName: `you/${fields.title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .slice(0, 32)}`,
    baseRefName: "main",
    mergeState: "clean",
    review: "none",
    ...fields,
  };
}

/** Made-up PRs covering every state, for screenshots. Opened with launchContext {"demo": true}. */
export function demoPRs(now = Date.now()): LoadedPRs {
  const prs: PullRequest[] = [
    pr(now, {
      id: "PR_demo_1",
      repo: "acme/api",
      number: 412,
      title: "Retry webhooks with exponential backoff",
      updatedAt: ago(12, now),
      checks: [
        ...passing(16),
        { name: "test (ubuntu, node 22)", state: "failure", url: "https://github.com/acme/api/actions/runs/1/job/1" },
        { name: "e2e / checkout", state: "failure", url: "https://github.com/acme/api/actions/runs/1/job/2" },
      ],
      summary: "Webhook deliveries that time out are retried with backoff and jitter instead of being dropped.",
    }),
    pr(now, {
      id: "PR_demo_2",
      repo: "acme/web",
      number: 88,
      title: "Upgrade the dashboard to React 20",
      updatedAt: ago(25, now),
      review: "approved",
    }),
    pr(now, {
      id: "PR_demo_3",
      repo: "acme/api",
      number: 405,
      title: "Rate-limit the public search endpoint",
      updatedAt: ago(95, now),
      review: "changesRequested",
    }),
    pr(now, {
      id: "PR_demo_4",
      repo: "acme/api",
      number: 409,
      title: "Add idempotency keys to payments",
      updatedAt: ago(8, now),
      review: "approved",
      mergeQueue: { position: 2, state: "QUEUED" },
    }),
    pr(now, {
      id: "PR_demo_7",
      repo: "acme/api",
      number: 398,
      title: "Split the billing worker into its own service",
      updatedAt: ago(60 * 26, now),
      baseRefName: "you/add-idempotency-keys-to-payments",
      mergeState: "behind",
    }),
    pr(now, {
      id: "PR_demo_5",
      repo: "acme/web",
      number: 91,
      title: "Keyboard shortcuts for the inbox",
      updatedAt: ago(4, now),
      checks: [...passing(9), ...["lint", "unit", "e2e"].map((name) => ({ name, state: "pending" as const }))],
      review: "reviewRequired",
    }),
    pr(now, {
      id: "PR_demo_6",
      repo: "acme/cli",
      number: 33,
      title: "Ship shell completions for zsh and fish",
      updatedAt: ago(180, now),
      review: "approved",
    }),
    pr(now, {
      id: "PR_demo_8",
      repo: "acme/web",
      number: 95,
      title: "Spike: edge caching for marketing pages",
      updatedAt: ago(60 * 24 * 4, now),
      isDraft: true,
      checks: [],
    }),
    pr(now, {
      id: "PR_demo_9",
      repo: "acme/web",
      number: 86,
      title: "Move auth to the new session store",
      status: "merged",
      mergedAt: ago(300, now),
      checks: [...passing(10), { name: "deploy / production", state: "failure" }],
      baseState: "failure",
    }),
    pr(now, {
      id: "PR_demo_10",
      repo: "acme/api",
      number: 401,
      title: "Log slow queries over 200 ms",
      status: "merged",
      mergedAt: ago(200, now),
      baseState: "success",
    }),
  ];
  const open = prs.filter((p) => p.status === "open").map((p) => p.id);
  const merged = prs.filter((p) => p.status === "merged").map((p) => p.id);
  return {
    source: "station",
    snapshot: {
      writtenAt: new Date(now).toISOString(),
      prs,
      pinnedIDs: [],
      sections: [
        { id: "Mine", title: "My PRs", prIDs: open },
        { id: "Merged", title: "Merged", prIDs: merged },
      ],
      colorProfile: "default",
    },
  };
}

const none: PRActivity = {
  comments: 0,
  commenters: [],
  threads: 0,
  unresolvedThreads: 0,
  reviews: [],
  requested: [],
  autoMerge: false,
};

export function demoActivity(now = Date.now()): ActivityMap {
  return {
    PR_demo_1: { ...none, comments: 5, commenters: ["alice"], threads: 3, unresolvedThreads: 2 },
    PR_demo_2: {
      ...none,
      comments: 1,
      commenters: ["bob"],
      reviews: [{ login: "bob", state: "APPROVED", at: ago(90, now) }],
      dropped: { at: ago(25, now), reason: "MERGE_GROUP_FAILED_CHECKS" },
    },
    PR_demo_3: {
      ...none,
      comments: 3,
      commenters: ["carol"],
      threads: 2,
      reviews: [{ login: "carol", state: "CHANGES_REQUESTED", at: ago(95, now) }],
    },
    PR_demo_4: {
      ...none,
      reviews: [{ login: "alice", state: "APPROVED", at: ago(40, now) }],
      queue: { position: 2, state: "QUEUED", enqueuedAt: ago(8, now) },
    },
    PR_demo_5: { ...none, requested: ["dana"] },
    PR_demo_6: { ...none, comments: 2, commenters: ["erin"], reviews: [{ login: "erin", state: "APPROVED" }] },
    PR_demo_7: none,
    PR_demo_8: none,
    PR_demo_9: none,
    PR_demo_10: none,
  };
}
