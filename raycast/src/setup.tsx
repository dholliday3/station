import {
  Action,
  ActionPanel,
  Alert,
  Application,
  Clipboard,
  confirmAlert,
  Icon,
  Keyboard,
  List,
  open,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { InstallError, installStation, InstallStep, STATION_RELEASES } from "./lib/install";
import { GH_INSTALL_COMMAND, GH_SIGN_IN_COMMAND, SetupStep } from "./lib/setup";
import { waitForStation } from "./lib/snapshot";

const STATION_REPO = "https://github.com/timmywheels/station";
const GH_SITE = "https://cli.github.com";

const stepTitles: Record<InstallStep, string> = {
  downloading: "Downloading Station…",
  verifying: "Checking its signature…",
  installing: "Installing…",
  opening: "Opening Station…",
};

/** Once Station is open it needs a moment, and a first launch needs its sign-in, before it serves the list. */
async function whenStationAnswers(toast: Toast, refresh: () => void) {
  toast.title = "Waiting for Station…";
  if (await waitForStation()) {
    toast.style = Toast.Style.Success;
    toast.title = "Station is running";
    toast.message = undefined;
    refresh();
    return;
  }
  toast.style = Toast.Style.Success;
  toast.title = "Station is open";
  toast.message = "Finish its setup, then refresh here with ⌘R.";
}

async function install(refresh: () => void) {
  const confirmed = await confirmAlert({
    title: "Install Station?",
    message:
      "Downloads the latest release from GitHub (about 15 MB), checks it's signed and notarized, puts it in Applications, and opens it.",
    primaryAction: { title: "Install", style: Alert.ActionStyle.Default },
  });
  if (!confirmed) return;
  const toast = await showToast({ style: Toast.Style.Animated, title: stepTitles.downloading });
  try {
    await installStation((step) => (toast.title = stepTitles[step]));
    await whenStationAnswers(toast, refresh);
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "Couldn't install Station";
    toast.message = error instanceof InstallError ? error.message : String(error);
    toast.primaryAction = { title: "Open Download Page", onAction: () => open(STATION_RELEASES) };
  }
}

async function start(station: Application, refresh: () => void) {
  const toast = await showToast({ style: Toast.Style.Animated, title: "Starting Station…" });
  await open(station.path);
  await whenStationAnswers(toast, refresh);
}

async function copyCommand(command: string) {
  await Clipboard.copy(command);
  await showHUD(`Copied “${command}”. Paste it into a terminal.`);
}

function StepActions(props: {
  step: SetupStep;
  station?: Application;
  hasBrew: boolean;
  refresh: () => void;
  dismiss: () => void;
}) {
  const { step, station, refresh } = props;
  const main = {
    "install-station": [
      <Action key="install" title="Install Station" icon={Icon.Download} onAction={() => install(refresh)} />,
      <Action.OpenInBrowser key="page" title="Open Download Page" url={STATION_RELEASES} />,
      <Action.OpenInBrowser key="about" title="Learn About Station" icon={Icon.Info} url={STATION_REPO} />,
    ],
    "start-station": station
      ? [
          <Action
            key="start"
            title="Start Station"
            icon={{ fileIcon: station.path }}
            onAction={() => start(station, refresh)}
          />,
        ]
      : [],
    "install-gh": props.hasBrew
      ? [
          <Action
            key="copy"
            title="Copy Install Command"
            icon={Icon.Terminal}
            onAction={() => copyCommand(GH_INSTALL_COMMAND)}
          />,
          <Action.OpenInBrowser key="site" title="Open GitHub CLI Site" url={GH_SITE} />,
        ]
      : [<Action.OpenInBrowser key="site" title="Open GitHub CLI Site" url={GH_SITE} />],
    "sign-in-gh": [
      <Action
        key="copy"
        title="Copy Sign-In Command"
        icon={Icon.Terminal}
        onAction={() => copyCommand(GH_SIGN_IN_COMMAND)}
      />,
      <Action.OpenInBrowser key="docs" title="Open Sign-In Guide" url={`${GH_SITE}/manual/gh_auth_login`} />,
    ],
  }[step.id];

  return (
    <ActionPanel title={step.title}>
      <ActionPanel.Section>{main}</ActionPanel.Section>
      <ActionPanel.Section>
        <Action
          title="Refresh"
          icon={Icon.ArrowClockwise}
          onAction={refresh}
          shortcut={Keyboard.Shortcut.Common.Refresh}
        />
        <Action
          title="Don't Show Again"
          icon={Icon.EyeDisabled}
          onAction={props.dismiss}
          shortcut={Keyboard.Shortcut.Common.Remove}
        />
      </ActionPanel.Section>
    </ActionPanel>
  );
}

/** Pinned above the PRs until each piece is in place or dismissed. */
export function SetupSection(props: {
  steps: SetupStep[];
  station?: Application;
  hasBrew: boolean;
  refresh: () => void;
  dismiss: (id: string) => void;
}) {
  if (!props.steps.length) return null;
  return (
    <List.Section title="SET UP">
      {props.steps.map((step) => (
        <List.Item
          key={step.id}
          id={`setup:${step.id}`}
          icon={step.id.endsWith("station") ? "extension-icon.png" : { source: Icon.Terminal }}
          title={step.title}
          subtitle={step.subtitle}
          actions={
            <StepActions
              step={step}
              station={props.station}
              hasBrew={props.hasBrew}
              refresh={props.refresh}
              dismiss={() => props.dismiss(step.id)}
            />
          }
        />
      ))}
    </List.Section>
  );
}
