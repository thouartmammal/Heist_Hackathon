import { initializeApp } from "https://www.gstatic.com/firebasejs/11.0.0/firebase-app.js";
import { 
  getAuth, createUserWithEmailAndPassword, signInWithEmailAndPassword, onAuthStateChanged 
} from "https://www.gstatic.com/firebasejs/11.0.0/firebase-auth.js";
import { 
  getFirestore, doc, setDoc, updateDoc, arrayUnion, getDoc 
} from "https://www.gstatic.com/firebasejs/11.0.0/firebase-firestore.js";

const env = window.env;

const firebaseConfig = {
  apiKey: "AIzaSyCBm3l2cYKBHR5MtRr7e5DTczE8a6GeqQ0",
  authDomain: "senseshift-ca8b0.firebaseapp.com",
  projectId: "senseshift-ca8b0",
  storageBucket: "senseshift-ca8b0.appspot.com",
  messagingSenderId: "210204427353",
  appId: "1:210204427353:web:6f8eadbace693ddec8dd48"
};


const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db = getFirestore(app);

export {
  auth,
  db,
  createUserWithEmailAndPassword,
  signInWithEmailAndPassword,
  onAuthStateChanged,
  doc,
  setDoc,
  updateDoc,
  arrayUnion,
  getDoc
};
