import {
  auth,
  db,
  onAuthStateChanged,
  doc,
  getDoc,
  updateDoc,
  arrayUnion,
  setDoc
} from './firebase-config.js';
// === DOM ELEMENTS ===
const relaxBtn = document.getElementById('relaxBtn');
const quoteDiv = document.getElementById('quote');
const searchBar = document.getElementById('searchBar');
const logList = document.getElementById('logList');

//
// 🧘 getQuote() — uses ZenQuotes.io safely through AllOrigins (no CORS errors)
//
async function getQuote(query = '') {
  try {
    // Get multiple quotes from ZenQuotes
    const response = await fetch(
      'https://api.allorigins.win/get?url=' +
      encodeURIComponent('https://zenquotes.io/api/quotes')
    );

    const wrapped = await response.json();
    const quotes = JSON.parse(wrapped.contents);

    // Search filter
    if (query) {
      const results = quotes.filter(q =>
        q.q.toLowerCase().includes(query.toLowerCase()) ||
        q.a.toLowerCase().includes(query.toLowerCase())
      );

      if (results.length > 0) {
        const random = results[Math.floor(Math.random() * results.length)];
        return `${random.q} — ${random.a}`;
      } else {
        return 'No matching quotes found.';
      }
    }

    // Random quote
    const random = quotes[Math.floor(Math.random() * quotes.length)];
    return `${random.q} — ${random.a}`;

  } catch (err) {
    console.error('Error fetching quote:', err);
    return 'Take a deep breath and be present.';
  }
}

//
// 🧾 Log user action to Firestore
//
async function logTrigger(entry) {
  const user = auth.currentUser;
  if (!user) return;

  try {
    const userRef = doc(db, 'users', user.uid);
    const userSnap = await getDoc(userRef);

    // If document doesn’t exist yet, create it
    if (!userSnap.exists()) {
      await setDoc(userRef, { logs: [entry] });
    } else {
      await updateDoc(userRef, { logs: arrayUnion(entry) });
    }

    prependLogToUI(entry);
  } catch (err) {
    console.error('Logging error:', err);
  }
}


//
// 🪵 Add log entry to the UI
//
function prependLogToUI(entry) {
  if (!logList) return;
  const li = document.createElement('li');
  li.textContent = `${new Date().toLocaleString()}: ${JSON.stringify(entry)}`;
  logList.insertBefore(li, logList.firstChild);
}

//
// 👤 Auth state check — load logs if signed in
//
onAuthStateChanged(auth, async (user) => {
  if (!user) {
    window.location.href = 'index.html';
    return;
  }

  try {
    const userSnap = await getDoc(doc(db, 'users', user.uid));
    if (userSnap.exists()) {
      const logs = userSnap.data().logs || [];
      logs.slice().reverse().forEach(prependLogToUI);
    }
  } catch (err) {
    console.error('Error loading logs:', err);
  }
});

//
// 🧘 Relax button — get a random quote and log the action
//
relaxBtn?.addEventListener('click', async () => {
  const phrase = "You are doing great — keep breathing 🌸";
  if (quoteDiv) quoteDiv.textContent = phrase;

  const entry = {
    type: 'manual_trigger',
    message: 'Mindfulness prompt triggered',
    timestamp: new Date().toISOString()
  };

  await logTrigger(entry);
  window.electronAPI.showNotification('Sense-Shift', 'You might be getting overwhelmed, breathe...');
  setTimeout(()=>{
    if (quoteDiv) {
    quoteDiv.textContent = 'Press the button to relax...';
  }
  },60000);

});

function showNotification(title, body) {
  new Notification({ title:title , body:body }).show();
}


//
// 🔍 Search bar — get quote when pressing Enter
//
searchBar?.addEventListener('keypress', async (e) => {
  if (e.key === 'Enter') {
    const query = searchBar.value.trim();
    if (query) {
      const quote = await getQuote(query);
      if (quoteDiv) quoteDiv.textContent = quote;
    }
  }
});
