import pandas as pd
import numpy as np

# Sources: 
# https://www.mdpi.com/2076-3417/15/19/10519
# https://www.researchgate.net/publication/365620378_Heart_and_Breathing_Rate_Variations_as_Biomarkers_for_Anxiety_Detection


np.random.seed(42)
n = 3000  # total samples
# probability of anxiety attack
p_anxiety = 0.2
n_anxiety = int(n * p_anxiety)
n_non_anxiety = n - n_anxiety

# Mean and std for each metric
stepCount_stats = [(8799.06, 5361.71), (8354.81, 4620.94)]
sleepHours_stats = [(7.61, 1.56), (7.6389, 1.6944)]
heartRate_stats = [(790.11,625.27), (643.2, 546.89)]
respiratoryRate_stats = [(16.32, 2.71), (16.84, 2.48)]
caloriesBurned_stats = [(2640.23, 663.72),(2475.15, 690.79)]

# Generate data for non-anxiety group
data_non_anxiety = pd.DataFrame({
    "stepCount": np.random.normal(loc=stepCount_stats[0][0], scale=stepCount_stats[0][1], size=n_non_anxiety),
    "sleepHours": np.random.normal(loc=sleepHours_stats[0][0], scale=sleepHours_stats[0][1], size=n_non_anxiety),
    "heartRate": np.random.normal(loc=heartRate_stats[0][0], scale=heartRate_stats[0][1], size=n_non_anxiety),
    "respiratoryRate": np.random.normal(loc=respiratoryRate_stats[0][0], scale=respiratoryRate_stats[0][1], size=n_non_anxiety),
    "caloriesBurned": np.random.normal(loc=caloriesBurned_stats[0][0], scale=caloriesBurned_stats[0][1], size=n_non_anxiety),
    "Overwhelmed": 0
})

# Generate data for anxiety attack group
data_anxiety = pd.DataFrame({
    "stepCount": np.random.normal(loc=stepCount_stats[1][0], scale=stepCount_stats[1][1], size=n_anxiety),
    "sleepHours": np.random.normal(loc=sleepHours_stats[1][0], scale=sleepHours_stats[1][1], size=n_anxiety),
    "heartRate": np.random.normal(loc=heartRate_stats[1][0], scale=heartRate_stats[1][1], size=n_anxiety),
    "respiratoryRate": np.random.normal(loc=respiratoryRate_stats[1][0], scale=respiratoryRate_stats[1][1], size=n_anxiety),
    "caloriesBurned": np.random.normal(loc=caloriesBurned_stats[1][0], scale=caloriesBurned_stats[1][1], size=n_anxiety),
    "Overwhelmed": 1
})

# Combine datasets
data = pd.concat([data_non_anxiety, data_anxiety], ignore_index=True)
data = data.sample(frac=1, random_state=42).reset_index(drop=True)  # shuffle rows

print(data.head())
print(len(data))
