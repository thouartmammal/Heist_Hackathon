# interface/trainModel.py
import sys, json, os, time
import numpy as np
import pandas as pd
import joblib
import optuna
import torch
import torch.nn as nn
import torch.optim as optim
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
import pyrebase

# ============ FIREBASE CONFIG ============
firebaseConfig = {
    "apiKey": "YOUR_KEY",
    "authDomain": "YOUR_DOMAIN",
    "databaseURL": "",
    "projectId": "YOUR_PROJECT_ID",
    "storageBucket": "YOUR_BUCKET",
    "messagingSenderId": "YOUR_SENDER_ID",
    "appId": "YOUR_APP_ID"
}

firebase = pyrebase.initialize_app(firebaseConfig)
db = firebase.database()
fs = firebase.firestore() if hasattr(firebase, "firestore") else None

# ============ MODEL DEFINITION ============
class OverwhelmDetector(nn.Module):
    def __init__(self, input_size, hidden_sizes, dropout_rate):
        super().__init__()
        layers = []
        prev = input_size
        for hs in hidden_sizes:
            layers.extend([nn.Linear(prev, hs), nn.ReLU(), nn.Dropout(dropout_rate)])
            prev = hs
        layers.append(nn.Linear(prev, 1))
        layers.append(nn.Sigmoid())
        self.model = nn.Sequential(*layers)

    def forward(self, x):
        return self.model(x)

# ============ TRAIN FUNCTION ============
def train_from_df(df, optuna_trials=5):
    df = df.copy()
    for col in df.columns:
        if col != "Overwhelmed":
            df[col] = df[col].apply(lambda x: np.nan if x < 0 else x)
            df[col] = df[col].fillna(df[col].mean())

    X = df.drop("Overwhelmed", axis=1).values
    y = df["Overwhelmed"].values
    X_train, X_test, y_train, y_test = train_test_split(X, y, stratify=y, test_size=0.2, random_state=42)
    scaler = StandardScaler()
    X_train = scaler.fit_transform(X_train)
    X_test = scaler.transform(X_test)
    X_train_t = torch.tensor(X_train, dtype=torch.float32)
    y_train_t = torch.tensor(y_train, dtype=torch.float32).unsqueeze(1)

    input_size = X_train_t.shape[1]

    def objective(trial):
        hl = trial.suggest_int("hidden_layers", 1, 3)
        hs = trial.suggest_int("hidden_size", 16, 64)
        dr = trial.suggest_float("dropout_rate", 0.1, 0.5)
        lr = trial.suggest_float("lr", 1e-4, 1e-2, log=True)
        batch = trial.suggest_categorical("batch_size", [32, 64, 128])

        model = OverwhelmDetector(input_size, [hs]*hl, dr)
        opt = optim.Adam(model.parameters(), lr=lr)
        loss_fn = nn.BCELoss()

        for _ in range(15):
            perm = torch.randperm(X_train_t.size(0))
            for i in range(0, X_train_t.size(0), batch):
                idx = perm[i:i+batch]
                bx, by = X_train_t[idx], y_train_t[idx]
                opt.zero_grad()
                out = model(bx)
                loss = loss_fn(out, by)
                loss.backward()
                opt.step()
        return loss.item()

    study = optuna.create_study(direction="minimize", suppress_warnings=True)
    study.optimize(objective, n_trials=optuna_trials)

    best = study.best_params
    model = OverwhelmDetector(input_size, [best["hidden_size"]]*best["hidden_layers"], best["dropout_rate"])
    opt = optim.Adam(model.parameters(), lr=best["lr"])
    loss_fn = nn.BCELoss()
    batch = best["batch_size"]

    for epoch in range(30):
        perm = torch.randperm(X_train_t.size(0))
        for i in range(0, X_train_t.size(0), batch):
            idx = perm[i:i+batch]
            bx, by = X_train_t[idx], y_train_t[idx]
            opt.zero_grad()
            out = model(bx)
            loss = loss_fn(out, by)
            loss.backward()
            opt.step()

    os.makedirs("models", exist_ok=True)
    torch.save(model.state_dict(), "models/overwhelm_detector.pth")
    joblib.dump(scaler, "models/scaler.pkl")
    return model, scaler

# ============ FIREBASE TO DF ============
def firebase_to_df(uid):
    try:
        user_logs = fs.collection("users").document(uid).get().to_dict().get("logs", [])
        if not user_logs:
            return None
        rows = []
        for log in user_logs:
            m = log.get("metrics", log)
            rows.append([
                m.get("steps", 0),
                m.get("sleep", 0),
                m.get("heartRate", 0),
                m.get("respRate", 0),
                m.get("calories", 0),
                m.get("brightness", 0),
                m.get("uptime", 0),
                m.get("oxygen", 0),
                1 if log.get("type") == "manual_trigger" else 0
            ])
        columns = ["steps", "sleep", "heartRate", "respRate", "calories", "brightness", "uptime", "oxygen", "Overwhelmed"]
        df = pd.DataFrame(rows, columns=columns)
        return df
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}))
        return None

# ============ PREDICT ============
def predict_latest(model, scaler, latest_entry):
    try:
        features = np.array([[latest_entry.get(k, 0) for k in ["steps","sleep","heartRate","respRate","calories","brightness","uptime","oxygen"]]])
        X_scaled = scaler.transform(features)
        x_t = torch.tensor(X_scaled, dtype=torch.float32)
        model.eval()
        with torch.no_grad():
            out = model(x_t).item()
        return "overwhelmed" if out > 0.5 else "not_overwhelmed"
    except Exception as e:
        return f"prediction_error: {e}"

# ============ MAIN LOOP ============
def main():
    uid = sys.argv[1] if len(sys.argv) > 1 else None
    if not uid:
        print(json.dumps({"status": "error", "message": "No UID passed"}))
        return

    last_seen_len = 0
    model, scaler = None, None

    while True:
        df = firebase_to_df(uid)
        if df is not None and len(df) > last_seen_len:
            model, scaler = train_from_df(df)
            last_seen_len = len(df)
            print(json.dumps({"status": "retrained", "rows": len(df)}))
            sys.stdout.flush()

        if model is not None and df is not None and len(df) > 0:
            latest = df.iloc[-1].to_dict()
            result = predict_latest(model, scaler, latest)
            if result == "overwhelmed":
                print(json.dumps({"prediction": "overwhelmed"}))
                sys.stdout.flush()

        time.sleep(60)  # check every 60s

if __name__ == "__main__":
    main()
