import {
  Action,
  ActionPanel,
  Application,
  Color,
  Detail,
  getApplications,
  getPreferenceValues,
  Icon,
  Keyboard,
  LaunchProps,
  List,
} from "@raycast/api";
import { useCachedPromise, usePromise } from "@raycast/utils";
import { ReactNode, useMemo, useState } from "react";
import { activityFromSnapshot, ActivityMap, fetchActivity, nodeID, PRActivity } from "./lib/activity";
import { refLabel, rowBadges, showsAuthor, stackDepths, stackLayout, viewerLogin } from "./lib/badges";
import { demoActivity, demoPRs } from "./lib/demo";
import { findGh } from "./lib/github";
import {
  actionsRunURL,
  checksURL,
  ColorProfile,
  compactAgo,
  isBranch,
  isStale,
  orderedRows,
  PullRequest,
  queueURL,
  reviewURL,
  Row,
  shareLink,
  shortRef,
  sortChecks,
} from "./lib/model";
import { loadPRs, NoSourceError } from "./lib/source";
import { columns, dimensions, Light, lightLabel, statusMark, statusTooltip, Verdict, verdict } from "./lib/status";
import {
  badgeAccessory,
  columnAccessory,
  failedCheckImage,
  glyph,
  lightIcon,
  markdownDot,
  statusImage,
  menuBarDots,
} from "./style";

interface Preferences {
  ghPath?: string;
}

const STATION_BUNDLE_ID = "com.timwheeler.station";
const STATION_DOWNLOAD = "https://github.com/timmywheels/station/releases/latest";

const LIGHTS: Light[] = ["needsYou", "waiting", "ready", "quiet", "merged"];

type Filter = "all" | Light;

interface ViewRow extends Row {
  activity?: PRActivity;
  verdict: Verdict;
  depth: number;
}

function accessories(row: ViewRow, pinned: boolean, profile: ColorProfile): List.Item.Accessory[] {
  const { pr } = row;
  const when = pr.mergedAt ?? pr.updatedAt;
  return [
    ...rowBadges(pr, row.section.id, pinned).map((badge) => badgeAccessory(badge, profile)),
    { text: compactAgo(when), tooltip: `${pr.mergedAt ? "Merged" : "Updated"} ${new Date(when).toLocaleString()}` },
    ...columns(pr, row.activity).map((column) => columnAccessory(column, profile)),
  ];
}

function detailMarkdown(row: ViewRow): string {
  const { pr, verdict: v } = row;
  const mark = statusMark(pr, v);
  const why = v.reasons.length ? ` · ${v.reasons.join(", ")}` : "";
  const lines = [
    `## ${pr.title}`,
    "",
    `${markdownDot(mark.kind === "dot" ? mark.state : mark.broken ? "failure" : "merged")} **${lightLabel[v.light]}**${why}`,
    "",
  ];
  for (const d of dimensions(pr, row.activity)) {
    lines.push(`${markdownDot(d.state)} **${d.label}** · ${d.summary}  `);
    if (d.slot !== "ci") continue;
    for (const check of sortChecks(pr.checks).filter((c) => c.state === "failure")) {
      lines.push(`    ![](${failedCheckImage()}) ${check.url ? `[${check.name}](${check.url})` : check.name}  `);
    }
  }
  if (!row.activity) lines.push("", "_Comments, reviewers and queue history load from GitHub…_");
  if (pr.summary) lines.push("", "---", "", pr.summary.replace(/\n/g, "\n\n"));
  return lines.join("\n");
}

function PRDetailView(props: { row: ViewRow; station?: Application; refresh: () => void }) {
  const { pr } = props.row;
  const run = actionsRunURL(pr);
  const queue = queueURL(pr);
  const when = pr.mergedAt ?? pr.updatedAt;
  return (
    <Detail
      navigationTitle={shortRef(pr)}
      markdown={detailMarkdown(props.row)}
      metadata={
        <Detail.Metadata>
          {!isBranch(pr) && <Detail.Metadata.Link title={pr.repo} text={`#${pr.number}`} target={pr.url} />}
          <Detail.Metadata.Label
            title="Branch"
            icon={glyph("branch", Color.SecondaryText)}
            text={pr.baseRefName ? `${pr.headRefName} → ${pr.baseRefName}` : pr.headRefName}
          />
          {pr.author && <Detail.Metadata.Label title="Author" text={`@${pr.author}`} />}
          <Detail.Metadata.Label
            title={pr.mergedAt ? "Merged" : "Updated"}
            text={`${compactAgo(when)} ago · ${new Date(when).toLocaleString()}`}
          />
          <Detail.Metadata.Separator />
          {pr.checks.length > 0 && <Detail.Metadata.Link title="Checks" text="Checks tab" target={checksURL(pr)} />}
          {run && <Detail.Metadata.Link title="Actions" text="Run summary" target={run} />}
          {queue && <Detail.Metadata.Link title="Merge queue" text={pr.baseRefName} target={queue} />}
          {!isBranch(pr) && <Detail.Metadata.Link title="Files" text="Files changed" target={`${pr.url}/files`} />}
        </Detail.Metadata>
      }
      actions={<PRActions pr={pr} station={props.station} refresh={props.refresh} />}
    />
  );
}

/** ↵ is the first action, ⌘↵ the second; in the list the first one opens the details page. */
function PRActions(props: { pr: PullRequest; station?: Application; refresh: () => void; details?: ReactNode }) {
  const { pr, station } = props;
  const run = actionsRunURL(pr);
  const queue = queueURL(pr);

  return (
    <ActionPanel title={shortRef(pr)}>
      <ActionPanel.Section>
        {props.details && <Action.Push title="Show Details" icon={Icon.Sidebar} target={props.details} />}
        {station && !isBranch(pr) && (
          <Action.Open
            title="Review in Station"
            icon={{ fileIcon: station.path }}
            target={reviewURL(pr)}
            application={station}
          />
        )}
        <Action.OpenInBrowser
          title={isBranch(pr) ? "Open Commit on GitHub" : "Open on GitHub"}
          icon={Icon.ArrowNe}
          url={pr.url}
          shortcut={Keyboard.Shortcut.Common.Open}
        />
      </ActionPanel.Section>
      <ActionPanel.Section title="Dig Deeper">
        {!isBranch(pr) && (
          <Action.OpenInBrowser
            title="Open Files Changed"
            icon={Icon.Document}
            url={`${pr.url}/files`}
            shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
          />
        )}
        {run && (
          <Action.OpenInBrowser
            title="Open Actions Run"
            icon={Icon.BulletPoints}
            url={run}
            shortcut={{ modifiers: ["cmd", "shift"], key: "a" }}
          />
        )}
        {pr.checks.length > 0 && (
          <Action.OpenInBrowser
            title="Open Checks Tab"
            icon={Icon.CheckList}
            url={checksURL(pr)}
            shortcut={{ modifiers: ["cmd", "shift"], key: "k" }}
          />
        )}
        {queue && (
          <Action.OpenInBrowser
            title="Open Merge Queue"
            icon={glyph("queue")}
            url={queue}
            shortcut={{ modifiers: ["cmd", "shift"], key: "m" }}
          />
        )}
      </ActionPanel.Section>
      <ActionPanel.Section title="Copy">
        <Action.CopyToClipboard
          title="Copy URL"
          icon={Icon.CopyClipboard}
          content={pr.url}
          shortcut={Keyboard.Shortcut.Common.Copy}
        />
        <Action.CopyToClipboard
          title="Share (Title as a Link)"
          icon={Icon.Upload}
          content={shareLink(pr)}
          shortcut={{ modifiers: ["cmd", "shift"], key: "l" }}
        />
        {pr.headRefName && (
          <Action.CopyToClipboard
            title="Copy Branch Name"
            icon={glyph("branch")}
            content={pr.headRefName}
            shortcut={{ modifiers: ["cmd"], key: "b" }}
          />
        )}
        {pr.headSha && (
          <Action.CopyToClipboard
            title={`Copy Commit Hash (${pr.headSha.slice(0, 7)})`}
            icon={Icon.Hashtag}
            content={pr.headSha}
            shortcut={{ modifiers: ["cmd", "shift"], key: "b" }}
          />
        )}
      </ActionPanel.Section>
      <ActionPanel.Section>
        <Action
          title="Refresh"
          icon={Icon.ArrowClockwise}
          onAction={props.refresh}
          shortcut={Keyboard.Shortcut.Common.Refresh}
        />
        {station ? (
          <Action.Open
            title="Open Station"
            icon={{ fileIcon: station.path }}
            target={station.path}
            shortcut={{ modifiers: ["cmd", "opt"], key: "o" }}
          />
        ) : (
          <Action.OpenInBrowser title="Get Station" icon={Icon.Download} url={STATION_DOWNLOAD} />
        )}
      </ActionPanel.Section>
    </ActionPanel>
  );
}

function FilterDropdown(props: {
  counts: Record<Light, number>;
  total: number;
  profile: ColorProfile;
  onChange: (f: Filter) => void;
}) {
  return (
    <List.Dropdown
      tooltip="Filter by where each PR stands"
      storeValue
      onChange={(value) => props.onChange(value as Filter)}
    >
      <List.Dropdown.Item title={`All  ${props.total}`} value="all" icon={menuBarDots} />
      {LIGHTS.map((light) => (
        <List.Dropdown.Item
          key={light}
          title={`${lightLabel[light]}  ${props.counts[light]}`}
          value={light}
          icon={lightIcon(light, props.profile)}
        />
      ))}
    </List.Dropdown>
  );
}

/** Sections and rows in Station's order, with each stacked PR under its parent the way Station lays them out. */
function groupBySection(rows: ViewRow[]): { id: string; title: string; rows: ViewRow[] }[] {
  const groups: { id: string; title: string; rows: ViewRow[] }[] = [];
  for (const row of rows) {
    const last = groups[groups.length - 1];
    if (last?.id === row.section.id) last.rows.push(row);
    else groups.push({ id: row.section.id, title: row.section.title, rows: [row] });
  }
  return groups.map((group) => ({ ...group, rows: stackLayout(group.rows) }));
}

async function loadActivity(ids: string[], ghPath?: string, demo?: boolean): Promise<ActivityMap> {
  if (demo) return demoActivity();
  const gh = findGh(ghPath?.trim() || undefined);
  return gh ? fetchActivity(gh, ids) : {};
}

type LaunchContext = { search?: string; demo?: boolean; pr?: number };

export default function Command(props: LaunchProps<{ launchContext?: LaunchContext }>) {
  const { ghPath } = getPreferenceValues<Preferences>();
  const demo = props.launchContext?.demo === true;
  const [filter, setFilter] = useState<Filter>("all");
  const [searchText, setSearchText] = useState(props.launchContext?.search ?? "");

  const { data, isLoading, error, revalidate } = useCachedPromise(
    async (path?: string, demo?: boolean) => (demo ? demoPRs() : loadPRs({ ghPath: path })),
    [ghPath, demo],
    { keepPreviousData: true },
  );
  const prIDs = useMemo(
    () => [...new Set((data?.snapshot.prs ?? []).filter((pr) => !isBranch(pr)).map((pr) => nodeID(pr.id)))].sort(),
    [data],
  );
  const {
    data: activity,
    isLoading: activityLoading,
    revalidate: revalidateActivity,
  } = useCachedPromise(loadActivity, [prIDs, ghPath, demo], { execute: prIDs.length > 0, keepPreviousData: true });
  const { data: apps } = usePromise(getApplications);
  const station = apps?.find((app) => app.bundleId === STATION_BUNDLE_ID);

  const profile = data?.snapshot.colorProfile ?? "default";
  const rows = useMemo<ViewRow[]>(() => {
    if (!data) return [];
    const depths = stackDepths(data.snapshot.prs);
    return orderedRows(data.snapshot).map((row) => {
      const a = activity?.[nodeID(row.pr.id)] ?? activityFromSnapshot(row.pr);
      return { ...row, activity: a, verdict: verdict(row.pr, a), depth: depths.get(row.pr.id) ?? 0 };
    });
  }, [data, activity]);
  const counts = useMemo(() => {
    const out = Object.fromEntries(LIGHTS.map((l) => [l, 0])) as Record<Light, number>;
    const seen = new Set<string>();
    for (const row of rows) {
      if (seen.has(row.pr.id)) continue;
      seen.add(row.pr.id);
      out[row.verdict.light] += 1;
    }
    return out;
  }, [rows]);
  const pinned = useMemo(() => new Set(data?.snapshot.pinnedIDs ?? []), [data]);
  const viewer = useMemo(() => (data ? viewerLogin(data.snapshot.prs, data.snapshot.sections) : undefined), [data]);
  const visible = filter === "all" ? rows : rows.filter((row) => row.verdict.light === filter);
  const total = new Set(rows.map((row) => row.pr.id)).size;
  const refresh = () => {
    revalidate();
    revalidateActivity();
  };

  const linked = props.launchContext?.pr;
  const linkedRow = linked ? rows.find((row) => row.pr.number === linked) : undefined;
  if (linkedRow) return <PRDetailView row={linkedRow} station={station} refresh={refresh} />;

  const navigationTitle =
    data?.source === "gh"
      ? "Station · via GitHub CLI (Station isn't running)"
      : data && isStale(data.snapshot)
        ? `Station · last updated ${compactAgo(data.snapshot.writtenAt)} ago`
        : "Station";

  return (
    <List
      isLoading={isLoading || activityLoading}
      filtering
      searchText={searchText}
      onSearchTextChange={setSearchText}
      navigationTitle={navigationTitle}
      searchBarPlaceholder={total ? `Search ${total} pull requests…` : "Search pull requests…"}
      searchBarAccessory={<FilterDropdown counts={counts} total={total} profile={profile} onChange={setFilter} />}
    >
      {error && !data ? (
        <List.EmptyView
          icon={glyph("warning", Color.SecondaryText)}
          title={error instanceof NoSourceError ? "Nothing to read from" : "Couldn't load pull requests"}
          description={error.message}
          actions={
            <ActionPanel>
              {station && <Action.Open title="Open Station" target={station.path} />}
              <Action title="Try Again" icon={Icon.ArrowClockwise} onAction={refresh} />
            </ActionPanel>
          }
        />
      ) : (
        <List.EmptyView
          icon={filter === "all" ? menuBarDots : lightIcon(filter, profile)}
          title={filter === "all" ? "No open PRs" : `Nothing marked ${lightLabel[filter].toLowerCase()}`}
          description={filter === "all" ? undefined : "Pick another filter to see the rest."}
        />
      )}
      {groupBySection(visible).map((group) => (
        <List.Section key={group.id} title={group.title.toUpperCase()} subtitle={String(group.rows.length)}>
          {group.rows.map((row) => {
            const { key, pr, section } = row;
            const ref = refLabel(pr, section);
            const indent = row.depth > 0 ? `${"   ".repeat(row.depth - 1)}↳ ` : "";
            return (
              <List.Item
                key={key}
                id={key}
                icon={{
                  value: statusImage(statusMark(pr, row.verdict), profile),
                  tooltip: statusTooltip(pr, row.verdict),
                }}
                title={`${indent}${pr.title}`}
                subtitle={showsAuthor(pr, section, viewer) ? `${ref} · @${pr.author}` : ref}
                keywords={[pr.repo, String(pr.number), pr.headRefName, pr.author].filter(Boolean)}
                accessories={accessories(row, pinned.has(pr.id), profile)}
                actions={
                  <PRActions
                    pr={pr}
                    station={station}
                    refresh={refresh}
                    details={<PRDetailView row={row} station={station} refresh={refresh} />}
                  />
                }
              />
            );
          })}
        </List.Section>
      ))}
    </List>
  );
}
