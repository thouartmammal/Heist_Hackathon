import { auth, db, createUserWithEmailAndPassword, signInWithEmailAndPassword, onAuthStateChanged, doc, setDoc } from './firebase-config.js';

const emailEl = document.getElementById('email');
const passwordEl = document.getElementById('password');
const authBtn = document.getElementById('authBtn');
const toggleMode = document.getElementById('toggleMode');
const toggleSpan = document.getElementById('toggleSpan');

let isSignup = false;

toggleMode.addEventListener('click', () => {
  isSignup = !isSignup;
  console.log("isSignup:", isSignup);
  authBtn.textContent = isSignup ? 'Sign Up' : 'Login';
  toggleSpan.textContent = isSignup ? 'Login' : 'Sign up';
});

onAuthStateChanged(auth, (user) => {
  if (user) window.location.href = 'dashboard.html';
});

authBtn.addEventListener('click', async () => {
  const email = emailEl.value.trim();
  const password = passwordEl.value.trim();
  if (!email || !password) return alert('Please fill in both fields.');

  try {
    if (isSignup) {
      const userCredential = await createUserWithEmailAndPassword(auth, email, password);
      await setDoc(doc(db, 'users', userCredential.user.uid), {
        email,
        createdAt: new Date(),
        logs: []
      });
      alert('Signup successful!');
    } else {
      await signInWithEmailAndPassword(auth, email, password);
    }
  } catch (err) {
    alert(err.message);
  }
});
