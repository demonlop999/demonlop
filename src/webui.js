import { exec, exit } from "kernelsu";

const modulePath = "/data/adb/modules/ultra_gaming_mode";
const controlPath = `${modulePath}/control.sh`;
const message = document.querySelector("#message");
const consentMessage = document.querySelector("#consentMessage");
const history = [];
const maxSamples = 60;
let consent = false;
let scriptsAllowed = false;
let currentProfile = "stock";
let activePage = "overview";
let editingGame = "";
let refreshing = false;
let dashboardLoaded = false;
let latestStatusData = [];
let quickHardwareSignature = null;
const detailSignatures = new Map();
let frequencyRanges = { cpu: null, gpu: null };
let frequencyInputsInitialized = false;
const touchedFrequencyInputs = new Set();
let installedPackages = new Set();

async function run(args) {
  if (typeof globalThis.ksu === "undefined" || typeof globalThis.ksu.exec !== "function") {
    throw new Error("API WebUI KernelSU indisponible. Ouvrez cette page dans un gestionnaire compatible.");
  }
  const result = await exec(`sh '${controlPath}' ${args}`);
  if (result.errno !== 0) {
    throw new Error(result.stderr || result.stdout || "La commande privilégiée a échoué.");
  }
  return result.stdout || "";
}

function showMessage(text, error = false) {
  const target = consent ? message : consentMessage;
  target.textContent = text;
  target.classList.toggle("danger", error);
}

function makeRow(label, value, className = "") {
  const item = document.createElement("div");
  item.className = "row";
  const title = document.createElement("span");
  title.textContent = label;
  const detail = document.createElement("strong");
  detail.className = className;
  detail.textContent = value;
  item.append(title, detail);
  return item;
}

function setControlsEnabled(enabled) {
  document.querySelectorAll(".controls button,.controls input,.controls select").forEach(control => {
    control.disabled = !enabled;
  });
  for (const id of ["cpuMin", "cpuMax", "gameMin", "gameMax"]) {
    document.querySelector(`#${id}`).disabled = !enabled || !frequencyRanges.cpu;
  }
  for (const id of ["gpuMax", "gameGpu"]) {
    document.querySelector(`#${id}`).disabled = !enabled || !frequencyRanges.gpu;
  }
  document.querySelectorAll(".game-actions button").forEach(button => {
    button.disabled = !enabled;
  });
  document.querySelectorAll(".profile").forEach(button => {
    button.disabled = !enabled;
    button.classList.toggle("active", enabled && button.dataset.profile === currentProfile);
  });
}

function updateConsent(enabled) {
  const wasEnabled = consent;
  consent = enabled;
  document.querySelector("#consentScreen").hidden = enabled;
  document.querySelector("#dashboard").hidden = !enabled;
  document.querySelector("#consentDot").classList.toggle("on", enabled);
  document.querySelector("#consentLabel").textContent = enabled ? "Consentement actif" : "Consentement requis";
  if (!enabled && wasEnabled) {
    document.querySelector("#risk").checked = false;
    document.querySelector("#privacyAccept").checked = false;
  }
  setControlsEnabled(enabled);
  if (enabled && !dashboardLoaded) {
    dashboardLoaded = true;
    void loadGames();
    void loadInstalledApps();
  }
}

function bytesToText(value) {
  const bytes = Number(value);
  if (!Number.isFinite(bytes) || bytes < 0) return "indisponible";
  const units = ["o", "Ko", "Mo", "Go", "To"];
  let amount = bytes;
  let unit = 0;
  while (amount >= 1024 && unit < units.length - 1) {
    amount /= 1024;
    unit++;
  }
  return `${amount.toFixed(unit > 0 ? 1 : 0)} ${units[unit]}`;
}

function formatMHz(value, gpu = false) {
  const frequency = Number(value);
  if (!Number.isFinite(frequency) || frequency <= 0) return "";
  const mhz = frequency >= 100000000 ? frequency / 1000000
    : frequency >= 100000 ? frequency / 1000 : frequency;
  return `${mhz.toFixed(0)} MHz`;
}

function rawFrequencyToMHz(value) {
  const frequency = Number(value);
  if (!Number.isFinite(frequency) || frequency <= 0) return null;
  return Math.round(frequency >= 100000000 ? frequency / 1000000
    : frequency >= 100000 ? frequency / 1000 : frequency);
}

function setFrequencyInput(id, range, initialValue) {
  const input = document.querySelector(`#${id}`);
  if (!range) {
    input.value = "";
    input.disabled = true;
    return;
  }
  input.disabled = !consent;
  input.min = String(range.min);
  input.max = String(range.max);
  if (!touchedFrequencyInputs.has(id) && !frequencyInputsInitialized && initialValue !== undefined) input.value = String(initialValue);
  else if (Number(input.value) < range.min || Number(input.value) > range.max) {
    input.value = String(Math.min(range.max, Math.max(range.min, Number(input.value) || range.min)));
  }
}

function configureFrequencyControls(data) {
  const cpu = data.filter(item => item.kind === "cpu_range")
    .map(({ parts }) => ({ min: rawFrequencyToMHz(parts[2]), max: rawFrequencyToMHz(parts[3]) }))
    .filter(range => range.min && range.max && range.min <= range.max);
  const gpu = data.filter(item => item.kind === "gpu_range")
    .map(({ parts }) => ({ min: rawFrequencyToMHz(parts[2]), max: rawFrequencyToMHz(parts[3]) }))
    .filter(range => range.min && range.max && range.min <= range.max);
  const combine = ranges => ranges.length ? {
    min: Math.min(...ranges.map(range => range.min)),
    max: Math.max(...ranges.map(range => range.max))
  } : null;
  frequencyRanges = { cpu: combine(cpu), gpu: combine(gpu) };
  const cpuRange = frequencyRanges.cpu;
  const gpuRange = frequencyRanges.gpu;
  const cpuMinDefault = cpu.length ? Math.min(...cpu.map(range => range.min)) : undefined;
  const cpuMaxDefault = cpuRange?.max;
  const gpuMaxDefault = gpuRange?.max;
  for (const id of ["cpuMin", "gameMin"]) setFrequencyInput(id, cpuRange, cpuMinDefault);
  for (const id of ["cpuMax", "gameMax"]) setFrequencyInput(id, cpuRange, cpuMaxDefault);
  for (const id of ["gpuMax", "gameGpu"]) setFrequencyInput(id, gpuRange, gpuMaxDefault);
  document.querySelector("#frequencyRange").textContent = cpuRange && gpuRange
    ? `CPU ${cpuRange.min}–${cpuRange.max} · GPU ${gpuRange.min}–${gpuRange.max} MHz`
    : cpuRange ? `CPU ${cpuRange.min}–${cpuRange.max} MHz · GPU indisponible`
      : gpuRange ? `CPU indisponible · GPU ${gpuRange.min}–${gpuRange.max} MHz`
        : "Fréquences indisponibles";
  if (cpuRange && gpuRange) frequencyInputsInitialized = true;
}

function drawThermalChart() {
  const canvas = document.querySelector("#thermalChart");
  if (!canvas) return;
  const bounds = canvas.getBoundingClientRect();
  if (!bounds.width || !bounds.height) return;
  const ratio = window.devicePixelRatio || 1;
  const pixelWidth = Math.floor(bounds.width * ratio);
  const pixelHeight = Math.floor(bounds.height * ratio);
  if (canvas.width !== pixelWidth || canvas.height !== pixelHeight) {
    canvas.width = pixelWidth;
    canvas.height = pixelHeight;
  }
  const context = canvas.getContext("2d");
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  const width = bounds.width;
  const height = bounds.height;
  context.clearRect(0, 0, width, height);
  const padding = { top: 12, right: 7, bottom: 10, left: 30 };
  const chartWidth = width - padding.left - padding.right;
  const chartHeight = height - padding.top - padding.bottom;
  const values = history.slice(-maxSamples);
  const maxTemp = Math.max(90, ...values);
  const minTemp = Math.min(20, ...values);

  context.font = "10px system-ui";
  context.textAlign = "right";
  [30, 50, 70, 90].forEach(temp => {
    const y = padding.top + chartHeight * (1 - (temp - minTemp) / Math.max(1, maxTemp - minTemp));
    if (y < padding.top || y > padding.top + chartHeight) return;
    context.strokeStyle = "rgba(220,235,255,.09)";
    context.beginPath();
    context.moveTo(padding.left, y);
    context.lineTo(width - padding.right, y);
    context.stroke();
    context.fillStyle = "#8492a8";
    context.fillText(`${temp}°`, padding.left - 6, y + 3);
  });
  setText("#sampleCount", `${values.length} mesures`);
  if (values.length === 0) {
    context.fillStyle = "#a4b1c4";
    context.textAlign = "center";
    context.fillText("En attente des données thermiques", width / 2, height / 2);
    return;
  }

  const points = values.map((value, index) => ({
    x: padding.left + (values.length === 1 ? chartWidth : chartWidth * index / (values.length - 1)),
    y: padding.top + chartHeight * (1 - (value - minTemp) / Math.max(1, maxTemp - minTemp))
  }));
  const fill = context.createLinearGradient(0, padding.top, 0, height);
  fill.addColorStop(0, "rgba(154,243,210,.24)");
  fill.addColorStop(1, "rgba(154,243,210,0)");
  context.beginPath();
  points.forEach((point, index) => index === 0 ? context.moveTo(point.x, point.y) : context.lineTo(point.x, point.y));
  context.lineTo(points[points.length - 1].x, height - padding.bottom);
  context.lineTo(points[0].x, height - padding.bottom);
  context.closePath();
  context.fillStyle = fill;
  context.fill();
  context.beginPath();
  points.forEach((point, index) => index === 0 ? context.moveTo(point.x, point.y) : context.lineTo(point.x, point.y));
  context.strokeStyle = values[values.length - 1] >= 75 ? "#ffd58d" : "#9af3d2";
  context.lineWidth = 2;
  context.lineJoin = "round";
  context.stroke();
}

function renderProfile(profile) {
  currentProfile = profile || "stock";
  const readable = { stock: "Origine", balanced: "Équilibré", gaming: "Jeu" };
  const label = readable[currentProfile] || (currentProfile.startsWith("game-") ? "Profil jeu" : currentProfile);
  document.querySelector("#profileChip").textContent = label;
  document.querySelector("#statProfile").textContent = label;
  document.querySelectorAll(".profile").forEach(button => {
    button.classList.toggle("active", consent && button.dataset.profile === currentProfile);
  });
}

function setDeviceValue(id, value) {
  const element = document.querySelector(id);
  if (element && value && element.textContent !== value) element.textContent = value;
}

function setText(selector, value) {
  const element = document.querySelector(selector);
  if (element && element.textContent !== value) element.textContent = value;
}

function setMeter(selector, value) {
  const element = document.querySelector(selector);
  const width = `${Math.min(100, Math.max(0, value))}%`;
  if (element && element.style.width !== width) element.style.width = width;
}

function renderStats(data) {
  const temperatures = data.filter(item => item.kind === "thermal")
    .map(item => Number(item.parts[2]))
    .filter(Number.isFinite);
  if (temperatures.length) {
    const maxTemp = Math.max(...temperatures);
    setText("#statTemp", `${maxTemp.toFixed(1)}°`);
    setText("#statThermalFoot", maxTemp >= 75 ? "Profil jeu limité · seuil atteint" : "Capteurs accessibles");
  }

  for (const { kind, parts } of data) {
    if (kind === "battery" && parts[1] === "capacity") {
      setText("#statBattery", `${parts[2]}%`);
    } else if (kind === "battery" && parts[1] === "status") {
      setDeviceValue("#statBatteryFoot", parts[2]);
    } else if (kind === "memory") {
      const used = Number(parts[1]);
      const total = Number(parts[2]);
      const percent = Number(parts[3]);
      if ([used, total, percent].every(Number.isFinite)) {
        setText("#statMemory", `${percent.toFixed(0)}%`);
        setText("#statMemoryFoot", `${bytesToText(used * 1024)} sur ${bytesToText(total * 1024)}`);
        setMeter("#memoryMeter", percent);
      }
    } else if (kind === "storage") {
      const used = Number(parts[1]);
      const total = Number(parts[2]);
      const percent = Number(parts[3]);
      if ([used, total, percent].every(Number.isFinite)) {
        setText("#storageSummary", `${percent.toFixed(0)}%`);
        setText("#storageFoot", `${bytesToText(used * 1024)} utilisés sur ${bytesToText(total * 1024)}`);
        setMeter("#storageMeter", percent);
      }
    }
  }
}

function renderQuickHardware(data) {
  const hardware = data.filter(({ kind }) =>
    kind === "cpu" || kind === "gpu" || kind === "cpu_freq" || kind === "gpu_freq"
  );
  const signature = hardware.map(({ parts }) => parts.join("|")).join("\n");
  if (signature === quickHardwareSignature) return;
  quickHardwareSignature = signature;
  const quick = document.querySelector("#quickHardware");
  const fragment = document.createDocumentFragment();
  let count = 0;
  for (const { kind, parts } of data) {
    if (kind === "cpu" || kind === "gpu") {
      fragment.append(makeRow(
        `Gouverneur · ${parts[1].split("/").pop()}`,
        parts[2] || "inconnu"
      ));
      count++;
    } else if (kind === "cpu_freq" || kind === "gpu_freq") {
      const frequency = formatMHz(parts[2]);
      if (frequency) {
        fragment.append(makeRow(
          `${kind === "cpu_freq" ? "CPU" : "GPU"} · ${parts[1].split("/").pop()}`,
          frequency
        ));
        count++;
      }
    }
  }
  if (!count) {
    fragment.append(Object.assign(document.createElement("p"), {
      className: "empty",
      textContent: "Aucune donnée CPU/GPU disponible."
    }));
  }
  quick.replaceChildren(fragment);
}

function renderDetails(data) {
  const device = document.querySelector("#deviceDetails");
  const battery = document.querySelector("#batteryDetails");
  const storage = document.querySelector("#storageDetails");
  const network = document.querySelector("#networkDetails");
  const cpus = document.querySelector("#cpuDetails");
  const gpus = document.querySelector("#gpuDetails");
  const quick = document.querySelector("#quickHardware");
  const targets = [device, battery, storage, network, cpus, gpus, quick];
  const signatures = new Map(targets.map(element => [element, []]));
  const targetForKind = {
    device,
    thermal: device,
    battery,
    memory: battery,
    storage,
    network,
    cpu,
    cpu_range: cpus,
    cpu_freq: cpus,
    gpu: gpus,
    gpu_range: gpus,
    gpu_freq: gpus
  };
  for (const { kind, parts } of data) {
    const target = targetForKind[kind];
    if (target) signatures.get(target).push(parts.join("|"));
    if (kind === "cpu" || kind === "cpu_freq" || kind === "gpu" || kind === "gpu_freq") {
      signatures.get(quick).push(parts.join("|"));
    }
  }
  const changed = new Set();
  for (const element of targets) {
    const signature = signatures.get(element).join("\n");
    if (detailSignatures.get(element) !== signature) changed.add(element);
  }
  if (!changed.size) return;
  const fragments = new Map([...changed].map(element => [element, document.createDocumentFragment()]));
  const append = (element, child) => fragments.get(element)?.append(child);
  let batteryCount = 0;
  let storageCount = 0;
  let networkCount = 0;

  for (const { kind, parts } of data) {
    const target = targetForKind[kind];
    if (target && !changed.has(target)) continue;
    if (!target && !["cpu", "cpu_freq", "gpu", "gpu_freq"].includes(kind)) continue;
    const [, key, value, extra] = parts;
    if (kind === "device") {
      const label = { model: "Modèle", manufacturer: "Fabricant", android: "Android", kernel: "Noyau", chipset: "SoC", uptime: "Temps actif (heures)", load: "Charge système" }[key] || key;
      append(device, makeRow(label, value || "Non exposé"));
    } else if (kind === "battery") {
      const labels = { capacity: "Charge", status: "État", temp: "Température", voltage_now: "Tension", current_now: "Courant" };
      const unit = key === "temp" ? " °C" : key === "voltage_now" ? " V" : key === "current_now" ? " mA" : key === "capacity" ? "%" : "";
      append(battery, makeRow(labels[key] || key, `${value}${unit}`, key === "temp" ? "temp" : ""));
      batteryCount++;
    } else if (kind === "memory") {
      append(battery, makeRow("RAM utilisée", `${bytesToText(Number(key) * 1024)} / ${bytesToText(Number(value) * 1024)} (${extra}%)`));
      batteryCount++;
    } else if (kind === "storage") {
      append(storage, makeRow("Espace utilisé", `${bytesToText(Number(key) * 1024)} / ${bytesToText(Number(value) * 1024)} (${extra}%)`));
      storageCount++;
    } else if (kind === "network") {
      append(network, makeRow(key, `↓ ${bytesToText(value)} · ↑ ${bytesToText(extra)}`));
      networkCount++;
    } else if (kind === "cpu") {
      const item = makeRow(`Gouverneur · ${key.split("/").pop()}`, value || "inconnu");
      append(cpus, item);
      append(quick, item.cloneNode(true));
    } else if (kind === "cpu_range") {
      const min = formatMHz(value);
      const max = formatMHz(extra);
      if (min && max) append(cpus, makeRow(`Plage · ${key.split("/").pop()}`, `${min} – ${max}`));
    } else if (kind === "cpu_freq") {
      const frequency = formatMHz(value);
      if (frequency) {
        append(cpus, makeRow(`Actuelle · ${key.split("/").pop()}`, frequency));
        append(quick, makeRow(`CPU · ${key.split("/").pop()}`, frequency));
      }
    } else if (kind === "gpu") {
      const item = makeRow(`Gouverneur · ${key.split("/").pop()}`, value || "inconnu");
      append(gpus, item);
      append(quick, item.cloneNode(true));
    } else if (kind === "gpu_freq") {
      const frequency = formatMHz(value, true);
      if (frequency) {
        append(gpus, makeRow(`Actuelle · ${key.split("/").pop()}`, frequency));
        append(quick, makeRow(`GPU · ${key.split("/").pop()}`, frequency));
      }
    } else if (kind === "gpu_range") {
      const min = formatMHz(value, true);
      const max = formatMHz(extra, true);
      if (min && max) append(gpus, makeRow(`Plage · ${key.split("/").pop()}`, `${min} – ${max}`));
    } else if (kind === "thermal") {
      const temperature = `${value} °C`;
      const item = makeRow(key || "Zone thermique", temperature, "temp");
      append(device, item.cloneNode(true));
    }
  }

  if (!fragments.get(cpus)?.childElementCount && changed.has(cpus)) append(cpus, Object.assign(document.createElement("p"), { className: "empty", textContent: "Aucune donnée CPU accessible." }));
  if (!fragments.get(gpus)?.childElementCount && changed.has(gpus)) append(gpus, Object.assign(document.createElement("p"), { className: "empty", textContent: "Aucune donnée GPU accessible." }));
  if (!fragments.get(device).childElementCount) append(device, Object.assign(document.createElement("p"), { className: "empty", textContent: "Informations système indisponibles." }));
  if (!batteryCount) append(battery, Object.assign(document.createElement("p"), { className: "empty", textContent: "Aucune mesure accessible." }));
  if (!storageCount) append(storage, Object.assign(document.createElement("p"), { className: "empty", textContent: "Espace /data indisponible." }));
  if (!networkCount) append(network, Object.assign(document.createElement("p"), { className: "empty", textContent: "Compteurs d'interface indisponibles." }));
  if (!fragments.get(quick)?.childElementCount && changed.has(quick)) append(quick, Object.assign(document.createElement("p"), { className: "empty", textContent: "Aucune donnée CPU/GPU disponible." }));
  for (const [element, fragment] of fragments) {
    element.replaceChildren(fragment);
    const signature = signatures.get(element).join("\n");
    detailSignatures.set(element, signature);
    if (element === quick) quickHardwareSignature = signature;
  }
}

function renderActivePage(data = latestStatusData) {
  if (!data.length) return;
  if (activePage === "overview") {
    renderStats(data);
    renderQuickHardware(data);
    drawThermalChart();
  } else if (activePage === "performancePage" || activePage === "devicePage") {
    renderDetails(data);
  }
}

async function refresh() {
  if (refreshing || document.hidden) return;
  refreshing = true;
  try {
    const output = await run("status");
    const data = output.trim().split("\n").filter(Boolean).map(line => {
      const parts = line.split("|");
      return { kind: parts[0], parts };
    });
    for (const { kind, parts } of data) {
      if (kind === "profile") renderProfile(parts[1]);
      else if (kind === "consent") updateConsent(parts[1] === "accepted");
      else if (kind === "scripts") {
        scriptsAllowed = parts[1] === "allowed";
        document.querySelector("#allowScripts").checked = scriptsAllowed;
        document.querySelector("#allowScriptsPrivacy").checked = scriptsAllowed;
        document.querySelector("#scriptStatus").textContent = scriptsAllowed ? "Autorisés" : "Désactivés";
      }
    }
    if (!consent) return;
    configureFrequencyControls(data);
    latestStatusData = data;
    const temperatures = data.filter(item => item.kind === "thermal")
      .map(item => Number(item.parts[2]))
      .filter(Number.isFinite);
    if (temperatures.length) {
      history.push(Math.max(...temperatures));
      if (history.length > maxSamples) history.shift();
    }
    renderActivePage(data);
  } catch (error) {
    showMessage(error.message, true);
  } finally {
    refreshing = false;
  }
}

function resetGameForm() {
  editingGame = "";
  document.querySelector("#gameFormTitle").textContent = "Nouveau profil de jeu";
  document.querySelector("#gameName").value = "";
  document.querySelector("#gamePackage").value = "";
  document.querySelector("#installedApps").value = "";
  document.querySelector("#gameScript").value = "";
  document.querySelector("#gameMin").value = String(frequencyRanges.cpu?.min || "");
  document.querySelector("#gameMax").value = String(frequencyRanges.cpu?.max || "");
  document.querySelector("#gameGpu").value = frequencyRanges.gpu ? String(frequencyRanges.gpu.max) : "";
  document.querySelector("#startAction").value = "gaming";
  document.querySelector("#stopAction").value = "balanced";
  document.querySelector("#cancelEdit").hidden = true;
}

async function loadInstalledApps() {
  const select = document.querySelector("#installedApps");
  select.replaceChildren(new Option("Chargement des applications…", ""));
  try {
    const output = await run("apps");
    const apps = output.trim().split("\n").filter(line => line.startsWith("app|")).map(line => line.split("|"));
    installedPackages = new Set(apps.map(([, packageName]) => packageName).filter(Boolean));
    select.replaceChildren(new Option(apps.length ? "Choisir une application installée…" : "Aucune application utilisateur trouvée", ""));
    for (const [, packageName, label] of apps) {
      if (!packageName || !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(packageName)) continue;
      select.add(new Option(label || packageName, packageName));
    }
    if (editingGame && !installedPackages.has(editingGame)) {
      select.add(new Option(`${editingGame} · non installée`, editingGame));
    }
  } catch (error) {
    installedPackages = new Set();
    select.replaceChildren(new Option("Liste des applications indisponible", ""));
    showMessage(error.message, true);
  }
}

async function loadGames() {
  const container = document.querySelector("#games");
  const summary = document.querySelector("#gameSummary");
  try {
    const output = await run("games");
    container.replaceChildren();
    const profiles = output.trim().split("\n").filter(line => line.startsWith("game|")).map(line => line.split("|"));
    document.querySelector("#gameCount").textContent = `${profiles.length} ${profiles.length === 1 ? "jeu" : "jeux"}`;
    summary.textContent = profiles.length ? `${profiles.length} profil${profiles.length > 1 ? "s" : ""} configuré${profiles.length > 1 ? "s" : ""}` : "Aucun jeu associé";
    if (!profiles.length) {
      container.append(Object.assign(document.createElement("p"), { className: "empty", textContent: "Aucun profil. Ajoutez un jeu dans le formulaire." }));
      return;
    }
    for (const parts of profiles) {
      const [, id, packageName, title, minCpu, maxCpu, gpu, action, script] = parts;
      const item = document.createElement("article");
      item.className = "game";
      const details = document.createElement("div");
      details.append(
        Object.assign(document.createElement("strong"), { textContent: title }),
        Object.assign(document.createElement("small"), { textContent: `${packageName} · CPU ${minCpu}–${maxCpu} MHz · GPU ${gpu ? `${gpu} MHz` : "non exposé"} · ${action} · script ${script || "aucun"}` })
      );
      const actions = document.createElement("div");
      actions.className = "game-actions";
      const apply = document.createElement("button");
      apply.className = "secondary";
      apply.type = "button";
      apply.textContent = "Activer";
      apply.addEventListener("click", () => applyGame(id));
      const edit = document.createElement("button");
      edit.className = "secondary";
      edit.type = "button";
      edit.textContent = "Modifier";
      edit.addEventListener("click", () => editGame(parts));
      const remove = document.createElement("button");
      remove.className = "danger-button";
      remove.type = "button";
      remove.textContent = "Supprimer";
      remove.addEventListener("click", () => removeGame(id, title));
      actions.append(apply, edit, remove);
      item.append(details, actions);
      container.append(item);
    }
    setControlsEnabled(consent);
  } catch (error) {
    container.replaceChildren(Object.assign(document.createElement("p"), { className: "danger", textContent: error.message }));
    summary.textContent = "Indisponible";
  }
}

function editGame(parts) {
  const [, id, packageName, title, minCpu, maxCpu, gpu, action, script, stopAction] = parts;
  editingGame = id;
  document.querySelector("#gameFormTitle").textContent = `Modifier · ${title}`;
  document.querySelector("#gameName").value = title;
  document.querySelector("#gamePackage").value = packageName;
  if (![...document.querySelector("#installedApps").options].some(option => option.value === packageName)) {
    document.querySelector("#installedApps").add(new Option(`${packageName} · non installée`, packageName));
  }
  document.querySelector("#installedApps").value = packageName;
  document.querySelector("#gameMin").value = minCpu;
  document.querySelector("#gameMax").value = maxCpu;
  document.querySelector("#gameGpu").value = gpu;
  document.querySelector("#startAction").value = action;
  document.querySelector("#stopAction").value = stopAction || "balanced";
  document.querySelector("#gameScript").value = script === "none" ? "" : script;
  document.querySelector("#cancelEdit").hidden = false;
  document.querySelector("#gameName").focus();
  showMessage(`Modification du profil ${title}.`);
}

async function applyGame(id) {
  if (!/^[a-zA-Z0-9._-]+$/.test(id) || id.startsWith(".") || id.endsWith(".") || id.includes("..")) {
    showMessage("Identifiant de jeu invalide.", true);
    return;
  }
  await perform(`apply-game '${id}'`, "Application du profil de jeu…");
}

async function removeGame(id, title) {
  if (!window.confirm(`Supprimer le profil « ${title} » ?`)) return;
  await perform(`remove-game '${id}'`, "Suppression du profil…");
  if (editingGame === id) resetGameForm();
}

async function perform(command, pendingText) {
  showMessage(pendingText);
  try {
    const result = (await run(command)).trim();
    showMessage(result || "Réglage enregistré.");
    await refresh();
    if (consent && command !== "accept risk-v2 privacy-v1") await loadGames();
  } catch (error) {
    showMessage(error.message, true);
  }
}

for (const [minId, maxId] of [["cpuMin", "cpuMax"], ["gameMin", "gameMax"]]) {
  document.querySelector(`#${minId}`).addEventListener("input", event => {
    const maximum = document.querySelector(`#${maxId}`);
    if (Number(event.target.value) > Number(maximum.value)) {
      maximum.value = event.target.value;
    }
  });
  document.querySelector(`#${maxId}`).addEventListener("input", event => {
    const minimum = document.querySelector(`#${minId}`);
    if (Number(event.target.value) < Number(minimum.value)) {
      minimum.value = event.target.value;
    }
  });
}
for (const id of ["cpuMin", "cpuMax", "gpuMax", "gameMin", "gameMax", "gameGpu"]) {
  document.querySelector(`#${id}`).addEventListener("input", () => touchedFrequencyInputs.add(id));
}

function navigate(pageId) {
  const target = document.getElementById(pageId);
  if (!target || !target.classList.contains("page")) return;
  document.querySelectorAll(".page").forEach(page => page.classList.toggle("active", page === target));
  activePage = pageId;
  document.querySelectorAll("[data-page-target]").forEach(button => button.classList.toggle("active", button.dataset.pageTarget === pageId));
  document.querySelector("#crumb").textContent = document.querySelector(`[data-page-target="${pageId}"] span:last-child`)?.textContent || target.querySelector("h1")?.textContent || "Gestion";
  renderActivePage();
}

document.querySelectorAll("[data-page-target]").forEach(button => button.addEventListener("click", () => navigate(button.dataset.pageTarget)));
document.querySelectorAll("[data-go]").forEach(button => button.addEventListener("click", () => navigate(button.dataset.go)));
document.querySelectorAll("[data-profile]").forEach(button => {
  button.addEventListener("click", () => perform(`apply '${button.dataset.profile}'`, `Application du profil ${button.dataset.profile}…`));
});

document.querySelector("#accept").addEventListener("click", async () => {
  if (!document.querySelector("#risk").checked || !document.querySelector("#privacyAccept").checked) {
    showMessage("Cochez les deux cases après lecture des risques et de la politique.", true);
    return;
  }
  await perform("accept risk-v2 privacy-v1", "Enregistrement du consentement…");
});

async function revokeConsent() {
  document.querySelector("#risk").checked = false;
  document.querySelector("#privacyAccept").checked = false;
  await perform("decline", "Retrait du consentement et restauration…");
  if (consent) showMessage("Le retrait a échoué; vérifiez les permissions root.", true);
  else exit();
}
document.querySelector("#decline").addEventListener("click", () => exit());
document.querySelector("#revokePrivacy").addEventListener("click", revokeConsent);

document.querySelector("#applyLimits").addEventListener("click", async () => {
  const min = Number(document.querySelector("#cpuMin").value);
  const max = Number(document.querySelector("#cpuMax").value);
  const gpuInput = document.querySelector("#gpuMax").value;
  const gpu = gpuInput ? Number(gpuInput) : null;
  if (!Number.isInteger(min) || !Number.isInteger(max) || !frequencyRanges.cpu
      || min < frequencyRanges.cpu.min || max > frequencyRanges.cpu.max || min > max
      || (gpu !== null && (!frequencyRanges.gpu || !Number.isInteger(gpu)
        || gpu < frequencyRanges.gpu.min || gpu > frequencyRanges.gpu.max))) {
    showMessage("Entrez des fréquences entières dans les plages MHz détectées.", true);
    return;
  }
  await perform(`set-cpu-mhz ${min} ${max}`, "Application des fréquences CPU…");
  if (consent && gpu !== null) await perform(`set-gpu-mhz ${gpu}`, "Application de la fréquence GPU…");
});

document.querySelector("#installedApps").addEventListener("change", event => {
  const packageName = event.target.value;
  document.querySelector("#gamePackage").value = packageName;
  if (!document.querySelector("#gameName").value.trim() && packageName) {
    const shortName = packageName.split(".").pop().replace(/[_-]+/g, " ");
    document.querySelector("#gameName").value = shortName.slice(0, 48);
  }
});
document.querySelector("#refreshApps").addEventListener("click", loadInstalledApps);

document.querySelector("#saveGame").addEventListener("click", async () => {
  const title = document.querySelector("#gameName").value.trim();
  const packageName = document.querySelector("#gamePackage").value.trim();
  const id = packageName.toLowerCase();
  if (!/^[a-zA-Z0-9._ -]{1,48}$/.test(title) || !/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(packageName)) {
    showMessage("Sélectionnez d’abord une application installée sur le téléphone.", true);
    return;
  }
  if (!installedPackages.has(packageName) && editingGame !== packageName.toLowerCase()) {
    showMessage("Choisissez une application dans la liste des applications installées.", true);
    return;
  }
  if (editingGame && editingGame !== id) {
    showMessage("Le paquet identifie le profil. Supprimez l’ancien profil puis créez-en un nouveau pour changer de paquet.", true);
    return;
  }
  const min = Number(document.querySelector("#gameMin").value);
  const max = Number(document.querySelector("#gameMax").value);
  const gpuInput = document.querySelector("#gameGpu").value;
  const gpu = gpuInput ? Number(gpuInput) : null;
  const start = document.querySelector("#startAction").value;
  const stop = document.querySelector("#stopAction").value;
  const script = document.querySelector("#gameScript").value.trim() || "none";
  if (!Number.isInteger(min) || !Number.isInteger(max) || !frequencyRanges.cpu
      || min < frequencyRanges.cpu.min || max > frequencyRanges.cpu.max || min > max
      || (gpu !== null && (!frequencyRanges.gpu || !Number.isInteger(gpu)
        || gpu < frequencyRanges.gpu.min || gpu > frequencyRanges.gpu.max))) {
    showMessage("Entrez des fréquences entières dans les plages MHz détectées.", true);
    return;
  }
  if (!/^(none|[a-zA-Z0-9_-]{1,48})$/.test(script)) {
    showMessage("Identifiant de script invalide.", true);
    return;
  }
  if (script !== "none" && !document.querySelector("#allowScripts").checked) {
    showMessage("Activez et enregistrez d’abord l’autorisation séparée des scripts root.", true);
    return;
  }
  await perform(`save-game '${id}' '${packageName}' '${title}' ${min} ${max} '${gpu ?? ""}' '${start}' '${stop}' '${script}'`, "Enregistrement du profil…");
  resetGameForm();
});

async function saveScriptPermission(inputId) {
  if (!consent) {
    showMessage("Acceptez d’abord les risques et la politique de confidentialité.", true);
    return;
  }
  const allowed = document.querySelector(`#${inputId}`).checked;
  await perform(`allow-scripts ${allowed ? "yes" : "no"}`, allowed ? "Autorisation root des scripts…" : "Désactivation des scripts root…");
  if (scriptsAllowed !== allowed) showMessage("Impossible d'enregistrer le choix des scripts.", true);
}
document.querySelector("#saveScriptConsent").addEventListener("click", () => saveScriptPermission("allowScripts"));
document.querySelector("#saveScriptsPrivacy").addEventListener("click", () => saveScriptPermission("allowScriptsPrivacy"));

document.querySelector("#cancelEdit").addEventListener("click", resetGameForm);
document.querySelector("#privacyToggle").addEventListener("click", () => {
  const details = document.querySelector("#riskDetails");
  details.hidden = !details.hidden;
});

document.querySelector("#refresh").addEventListener("click", refresh);
document.querySelector("#refresh").addEventListener("click", loadGames);
window.addEventListener("resize", () => {
  if (activePage === "overview") drawThermalChart();
});
setControlsEnabled(false);
refresh();
setInterval(refresh, 10000);
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && consent) void refresh();
});
