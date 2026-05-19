const config = window.EMAIL_CLASSIFIER_CONFIG || {};
const apiBaseUrl = (config.apiBaseUrl || "").replace(/\/$/, "");

const state = {
  emails: [],
  selectedId: null,
};

const rowsEl = document.querySelector("#emailRows");
const statusEl = document.querySelector("#statusText");
const totalEl = document.querySelector("#totalCount");
const highEl = document.querySelector("#highCount");
const categoryEl = document.querySelector("#categoryCount");
const detailEl = document.querySelector("#detailList");
const deleteButton = document.querySelector("#deleteButton");
const limitSelect = document.querySelector("#limitSelect");

document.querySelector("#refreshButton").addEventListener("click", loadEmails);
limitSelect.addEventListener("change", loadEmails);
deleteButton.addEventListener("click", deleteSelectedEmail);

loadEmails();

async function loadEmails() {
  if (!apiBaseUrl) {
    setStatus("API-Endpunkt fehlt");
    return;
  }

  setStatus("Lade Daten...");
  try {
    const response = await fetch(
      `${apiBaseUrl}/emails?limit=${limitSelect.value}`,
    );
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const payload = await response.json();
    state.emails = payload.items || [];
    state.selectedId = state.emails[0]?.email_id || null;
    render();
    setStatus(`${state.emails.length} Datensätze geladen`);
  } catch (error) {
    setStatus(`Fehler: ${error.message}`);
  }
}

function render() {
  rowsEl.innerHTML = "";
  state.emails.forEach((email) => {
    const row = document.createElement("tr");
    row.className = email.email_id === state.selectedId ? "selected" : "";
    row.innerHTML = `
      <td>
        <div class="subject">${escapeHtml(email.subject || "(ohne Betreff)")}</div>
        <div class="meta">${escapeHtml(email.sender || "unbekannt")}</div>
      </td>
      <td>${escapeHtml(labelCategory(email.category))}</td>
      <td><span class="badge ${escapeHtml(email.urgency || "low")}">${escapeHtml(labelUrgency(email.urgency))}</span></td>
      <td>${formatDate(email.received_at)}</td>
    `;
    row.addEventListener("click", () => {
      state.selectedId = email.email_id;
      render();
    });
    rowsEl.appendChild(row);
  });

  totalEl.textContent = state.emails.length;
  highEl.textContent = state.emails.filter(
    (email) => email.urgency === "high",
  ).length;
  categoryEl.textContent = new Set(
    state.emails.map((email) => email.category || "general"),
  ).size;
  renderDetails(
    state.emails.find((email) => email.email_id === state.selectedId),
  );
}

function renderDetails(email) {
  deleteButton.disabled = !email;
  if (!email) {
    detailEl.innerHTML = "<dt>Status</dt><dd>Keine E-Mail ausgewählt</dd>";
    return;
  }

  detailEl.innerHTML = `
    <dt>Betreff</dt><dd>${escapeHtml(email.subject || "(ohne Betreff)")}</dd>
    <dt>Absender</dt><dd>${escapeHtml(email.sender || "unbekannt")}</dd>
    <dt>Kategorie</dt><dd>${escapeHtml(labelCategory(email.category))}</dd>
    <dt>Dringlichkeit</dt><dd>${escapeHtml(labelUrgency(email.urgency))}</dd>
    <dt>Sentiment</dt><dd>${escapeHtml(labelSentiment(email.sentiment))}</dd>
    <dt>Sprache</dt><dd>${escapeHtml(labelLanguage(email.language))}</dd>
    <dt>Vorschau</dt><dd>${escapeHtml(email.preview || "-")}</dd>
    <dt>S3-Objekt</dt><dd>${escapeHtml(email.s3_key || "-")}</dd>
  `;
}

async function deleteSelectedEmail() {
  if (!state.selectedId) {
    return;
  }

  const emailId = state.selectedId;
  deleteButton.disabled = true;
  setStatus(`Lösche ${emailId}`);
  try {
    const response = await fetch(
      `${apiBaseUrl}/emails/${encodeURIComponent(emailId)}`,
      {
        method: "DELETE",
      },
    );
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    state.emails = state.emails.filter((email) => email.email_id !== emailId);
    state.selectedId = state.emails[0]?.email_id || null;
    render();
    setStatus("Datensatz gelöscht");
  } catch (error) {
    setStatus(`Fehler: ${error.message}`);
    deleteButton.disabled = false;
  }
}

function setStatus(message) {
  statusEl.textContent = message;
}

function formatDate(value) {
  if (!value) {
    return "-";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }
  return new Intl.DateTimeFormat("de-DE", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function labelCategory(value) {
  const labels = {
    billing: "Abrechnung",
    support_incident: "Support/Störung",
    sales: "Vertrieb",
    legal_privacy: "Datenschutz/Recht",
    contract: "Vertrag",
    hr: "Personal",
    general: "Allgemein",
  };
  return labels[value] || value || "Allgemein";
}

function labelUrgency(value) {
  const labels = { high: "Hoch", medium: "Mittel", low: "Niedrig" };
  return labels[value] || "Niedrig";
}

function labelSentiment(value) {
  const labels = {
    POSITIVE: "Positiv",
    NEGATIVE: "Negativ",
    NEUTRAL: "Neutral",
    MIXED: "Gemischt",
    UNKNOWN: "Unbekannt",
  };
  return labels[value] || value || "Unbekannt";
}

function labelLanguage(value) {
  const labels = {
    de: "Deutsch",
    en: "Englisch",
  };
  return labels[value] || value || "-";
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
