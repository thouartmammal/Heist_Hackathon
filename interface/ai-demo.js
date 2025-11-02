import {
  auth,
  db,
  doc,
  getDoc,
  updateDoc,
  arrayUnion,
  setDoc
} from './firebase-config.js';

const clickRateEl = document.getElementById('clickRate');
const tabSpeedEl = document.getElementById('tabSpeed');
const focusScoreEl = document.getElementById('focusScore');
const productivityCanvas = document.getElementById('productivityChart');
const aiStatusEl = document.getElementById('aiStatus');

const DEFAULT_PRODUCTIVITY_SERIES = [
  { label: '12 AM', score: 0.35 },
  { label: '3 AM', score: 0.42 },
  { label: '6 AM', score: 0.48 },
  { label: '9 AM', score: 0.68 },
  { label: '12 PM', score: 0.74 },
  { label: '3 PM', score: 0.61 },
  { label: '6 PM', score: 0.57 },
  { label: '9 PM', score: 0.49 },
  { label: '12 AM', score: 0.38 }
];

const BASE_STATE = {
  clickRate: 6.2,
  tabSpeed: 5.6,
  focus: 0.83,
  productivity: DEFAULT_PRODUCTIVITY_SERIES.map((entry) => ({ ...entry })),
  status: 'Calm focus',
  copy: 'Baseline metrics loaded from your recent study sessions.'
};

const TAB_SWITCH_THRESHOLD = 9.5;
const FOCUS_ALERT_THRESHOLD = 0.6;
const NOTIFICATION_COOLDOWN = 60_000;

function cloneState(value) {
  return JSON.parse(JSON.stringify(value));
}

let state = cloneState(BASE_STATE);
let driftInterval = null;
let driftKickoffTimeout = null;
let tabBurstTimeout = null;
let hiddenAt = null;
let lastNotificationAt = 0;
let toastTimeout = null;

const DRIFT_INTERVAL_MS = 4500;
const INITIAL_DRIFT_DELAY_MS = 1500;
const SIMULATED_BURST_DELAY_MS = 5000;

async function logTrigger(entry) {
  const user = auth.currentUser;
  if (!user) return;

  try {
    const userRef = doc(db, 'users', user.uid);
    const userSnap = await getDoc(userRef);

    if (!userSnap.exists()) {
      await setDoc(userRef, { logs: [entry] });
    } else {
      await updateDoc(userRef, { logs: arrayUnion(entry) });
    }
  } catch (err) {
    console.error('Logging error:', err);
  }
}

function renderProductivityChart(bands) {
  if (!productivityCanvas) return;
  const ctx = productivityCanvas.getContext('2d');
  if (!ctx) return;

  const width = productivityCanvas.width;
  const height = productivityCanvas.height;
  ctx.clearRect(0, 0, width, height);

  ctx.fillStyle = '#eef2ff';
  ctx.fillRect(0, 0, width, height);

  const paddingLeft = 50;
  const paddingRight = 24;
  const paddingTop = 30;
  const paddingBottom = 34;

  ctx.strokeStyle = 'rgba(70, 99, 201, 0.25)';
  ctx.lineWidth = 1;
  ctx.setLineDash([6, 6]);
  for (let i = 0; i <= 4; i += 1) {
    const y = paddingTop + ((height - paddingTop - paddingBottom) / 4) * i;
    ctx.beginPath();
    ctx.moveTo(paddingLeft, y);
    ctx.lineTo(width - paddingRight, y);
    ctx.stroke();
  }
  ctx.setLineDash([]);

  const series = bands && bands.length >= 2 ? bands : DEFAULT_PRODUCTIVITY_SERIES;

  const points = series.map((band, index) => {
    const usableWidth = width - paddingLeft - paddingRight;
    const usableHeight = height - paddingTop - paddingBottom;
    const x = paddingLeft + (usableWidth / (series.length - 1 || 1)) * index;
    const y = paddingTop + (1 - band.score) * usableHeight;
    return { x, y, label: band.label, value: `${Math.round(band.score * 100)}%` };
  });

  const lineGradient = ctx.createLinearGradient(paddingLeft, 0, width - paddingRight, 0);
  lineGradient.addColorStop(0, '#ff6b6b');
  lineGradient.addColorStop(0.25, '#d24bff');
  lineGradient.addColorStop(0.5, '#6d6bff');
  lineGradient.addColorStop(0.75, '#00a9ff');
  lineGradient.addColorStop(1, '#00c878');

  const fillGradient = ctx.createLinearGradient(0, paddingTop, 0, height - paddingBottom);
  fillGradient.addColorStop(0, 'rgba(105, 115, 255, 0.28)');
  fillGradient.addColorStop(1, 'rgba(105, 115, 255, 0)');
  ctx.beginPath();
  points.forEach((point, index) => {
    if (index === 0) {
      ctx.moveTo(point.x, point.y);
    } else {
      ctx.lineTo(point.x, point.y);
    }
  });
  const lastPoint = points[points.length - 1];
  const firstPoint = points[0];
  ctx.lineTo(lastPoint.x, height - paddingBottom);
  ctx.lineTo(firstPoint.x, height - paddingBottom);
  ctx.closePath();
  ctx.fillStyle = fillGradient;
  ctx.fill();

  ctx.strokeStyle = lineGradient;
  ctx.lineWidth = 3;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.beginPath();
  points.forEach((point, index) => {
    if (index === 0) {
      ctx.moveTo(point.x, point.y);
    } else {
      ctx.lineTo(point.x, point.y);
    }
  });
  ctx.stroke();

  points.forEach((point, index) => {
    const t = index / (points.length - 1 || 1);
    const colorStops = [
      { stop: 0, color: [255, 107, 107] },
      { stop: 0.33, color: [160, 71, 255] },
      { stop: 0.66, color: [0, 169, 255] },
      { stop: 1, color: [0, 200, 120] }
    ];
    let color = colorStops[colorStops.length - 1].color;
    for (let i = 0; i < colorStops.length - 1; i += 1) {
      const current = colorStops[i];
      const next = colorStops[i + 1];
      if (t >= current.stop && t <= next.stop) {
        const ratio = (t - current.stop) / (next.stop - current.stop || 1);
        color = current.color.map((channel, channelIndex) =>
          Math.round(channel + (next.color[channelIndex] - channel) * ratio)
        );
        break;
      }
    }
    ctx.fillStyle = `rgb(${color.join(',')})`;
    ctx.beginPath();
    ctx.arc(point.x, point.y, 5, 0, Math.PI * 2);
    ctx.fill();
  });

  ctx.font = '12px "Verdana", sans-serif';
  ctx.textAlign = 'center';
  ctx.fillStyle = '#122047';
  points.forEach((point) => {
    ctx.fillText(point.value, point.x, point.y - 12);
    ctx.fillText(point.label, point.x, height - 12);
  });

  ctx.save();
  ctx.translate(18, height / 2);
  ctx.rotate(-Math.PI / 2);
  ctx.fillStyle = '#1b233d';
  ctx.font = '14px "Verdana", sans-serif';
  ctx.textAlign = 'center';
  ctx.fillText('Productivity Score', 0, 0);
  ctx.restore();

  ctx.fillStyle = '#1b233d';
  ctx.font = '14px "Verdana", sans-serif';
  ctx.textAlign = 'center';
  ctx.fillText('Hour', width / 2, height - 4);
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max);
}

function renderState() {
  if (clickRateEl) clickRateEl.textContent = state.clickRate.toFixed(1);
  if (tabSpeedEl) tabSpeedEl.textContent = state.tabSpeed.toFixed(1);
  if (focusScoreEl) focusScoreEl.textContent = `${Math.round(state.focus * 100)}%`;
  if (aiStatusEl) aiStatusEl.textContent = `${state.status} — ${state.copy}`;
  renderProductivityChart(state.productivity);
}

function setStatus(status, copy) {
  state.status = status;
  state.copy = copy;
}

function showToast(message) {
  let toast = document.getElementById('aiToast');
  if (!toast) {
    toast = document.createElement('div');
    toast.id = 'aiToast';
    toast.className = 'ai-toast';
    document.body.appendChild(toast);
  }
  toast.textContent = message;
  toast.classList.add('visible');

  if (toastTimeout) {
    clearTimeout(toastTimeout);
  }

  toastTimeout = setTimeout(() => {
    toast.classList.remove('visible');
  }, 6500);
}

function maybeTriggerNotification(reason) {
  const now = Date.now();
  if (now - lastNotificationAt < NOTIFICATION_COOLDOWN) {
    return false;
  }

  if (state.tabSpeed >= TAB_SWITCH_THRESHOLD || state.focus <= FOCUS_ALERT_THRESHOLD) {
    lastNotificationAt = now;
    const body = 'Hey! It looks like you are a little overwhelmed. How about a short break for some breathing exercises?';
    setStatus('Mindfulness reminder', reason);
    showToast(body);
    window.electronAPI?.showNotification('SenseShift Mindfulness Nudge', body);

    logTrigger({
      type: 'ai_prompt',
      message: body,
      riskScore: Number((state.tabSpeed / 18).toFixed(2)),
      timestamp: new Date().toISOString()
    });
    return true;
  }
  return false;
}

function simulateNaturalDrift() {
  const drift = (Math.random() * 0.6) - 0.3;
  state.clickRate = clamp(state.clickRate + drift * 0.6, 4.8, 9.8);

  const tabDrift = (Math.random() * 0.8) - 0.4;
  state.tabSpeed = clamp(state.tabSpeed + tabDrift, 4.3, 12.5);

  const focusDrift = (Math.random() * 0.02) - 0.008;
  state.focus = clamp(state.focus + focusDrift, 0.45, 0.92);

  state.productivity = state.productivity.map((band, index) => {
    const bandDrift = (Math.random() * 0.03) - 0.012;
    const weight = index >= 3 && index <= 5 ? 0.7 : 0.4;
    return {
      ...band,
      score: clamp(band.score + bandDrift * weight, 0.3, 0.9)
    };
  });

  setStatus('Monitoring', 'Metrics are updating with live mouse and keyboard pace.');
  maybeTriggerNotification('Adaptive monitor spotted a spike in focus load.');
  renderState();
}

function handleFastTabSwitch(awayMs) {
  const multiplier = awayMs < 5_000 ? 1 : 0.4;
  state.tabSpeed = clamp(state.tabSpeed + (3 + Math.random() * 4) * multiplier, 5, 18);
  state.clickRate = clamp(state.clickRate + (0.7 + Math.random() * 1.8) * multiplier, 5, 15);
  state.focus = clamp(state.focus - (0.05 + Math.random() * 0.08) * multiplier, 0.35, 0.95);

  state.productivity = state.productivity.map((band, index) => {
    if (index === 1) {
      return { ...band, score: clamp(band.score - 0.08 * multiplier, 0.3, 0.9) };
    }
    if (index === 2 || index === 3) {
      return { ...band, score: clamp(band.score - 0.05 * multiplier, 0.3, 0.9) };
    }
    return band;
  });

  setStatus('Sharp multitasking detected', 'Rapid tab hopping increased your cognitive load.');
  maybeTriggerNotification('Rapid tab switching triggered a mindfulness reminder.');
  renderState();
}

function simulateTabBurst() {
  tabBurstTimeout = null;
  state.tabSpeed = clamp(state.tabSpeed + 6.5, 5, 18);
  state.clickRate = clamp(state.clickRate + 2.2, 5, 15);
  state.focus = clamp(state.focus - 0.2, 0.35, 0.95);

  state.productivity = state.productivity.map((band, index) => {
    if (index === 3) {
      return { ...band, score: clamp(band.score - 0.09, 0.3, 0.9) };
    }
    if (index === 4 || index === 5) {
      return { ...band, score: clamp(band.score - 0.06, 0.3, 0.9) };
    }
    return band;
  });

  const message = 'Hey! It looks like you are a little overwhelmed. How about a short break for some breathing exercises?';
  setStatus('Sharp multitasking detected', 'Rapid tab hopping increased your cognitive load.');
  renderState();
  const alerted = maybeTriggerNotification('Rapid tab switching triggered a mindfulness reminder.');
  if (!alerted) {
    showToast(message);
  }
  renderState();
}

function resetState() {
  if (driftInterval) {
    clearInterval(driftInterval);
    driftInterval = null;
  }
  if (driftKickoffTimeout) {
    clearTimeout(driftKickoffTimeout);
    driftKickoffTimeout = null;
  }
  if (tabBurstTimeout) {
    clearTimeout(tabBurstTimeout);
    tabBurstTimeout = null;
  }
  state = cloneState(BASE_STATE);
  hiddenAt = null;
  lastNotificationAt = 0;
  if (toastTimeout) {
    clearTimeout(toastTimeout);
    toastTimeout = null;
  }
  const toast = document.getElementById('aiToast');
  if (toast) {
    toast.classList.remove('visible');
  }
  setStatus('Monitoring', 'Metrics are updating with live mouse and keyboard pace.');
  renderState();
  driftKickoffTimeout = setTimeout(() => {
    simulateNaturalDrift();
    driftInterval = setInterval(simulateNaturalDrift, DRIFT_INTERVAL_MS);
  }, INITIAL_DRIFT_DELAY_MS);
  tabBurstTimeout = setTimeout(() => {
    simulateTabBurst();
  }, SIMULATED_BURST_DELAY_MS);
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    hiddenAt = performance.now();
  } else if (hiddenAt !== null) {
    const awayMs = performance.now() - hiddenAt;
    if (awayMs < 12_000) {
      handleFastTabSwitch(awayMs);
    } else {
      setStatus('Back in app', 'Welcome back! Metrics returned to monitoring mode.');
      renderState();
    }
    hiddenAt = null;
  }
});

resetState();
